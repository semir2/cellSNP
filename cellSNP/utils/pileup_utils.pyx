# Utilility functions for pileup SNPs
# Author: Yuanhua Huang
# Date: 22/08/2018

## TODO: samFile.fetch is more efficient, but may gives
## low quality reads, e.g., deletion or refskip

## Note, pileup is not the fastest way, fetch reads and deal 
## with CIGARs will be faster.

import sys
import pysam
import numpy as np
cimport libc.math as c_math
from .base_utils import id_mapping, unique_list
from ..version import __version__
from .cellsnp_utils cimport get_query_bases, get_query_qualities, c_max, c_min

VCF_HEADER = (
    '##fileformat=VCFv4.2\n'
    '##source=cellSNP_v%s\n'
    '##FILTER=<ID=PASS,Description="All filters passed">\n'
    '##FILTER=<ID=.,Description="Filter info not available">\n'
    '##INFO=<ID=DP,Number=1,Type=Integer,Description="total counts for ALT and '
    'REF">\n'
    '##INFO=<ID=AD,Number=1,Type=Integer,Description="total counts for ALT">\n'
    '##INFO=<ID=OTH,Number=1,Type=Integer,Description="total counts for other '
    'bases from REF and ALT">\n'
    '##FORMAT=<ID=GT,Number=1,Type=String,Description="Genotype">\n'
    '##FORMAT=<ID=PL,Number=G,Type=Integer,Description="List of Phred-scaled '
    'genotype likelihoods">\n'
    '##FORMAT=<ID=DP,Number=1,Type=Integer,Description="total counts for ALT and '
    'REF">\n'
    '##FORMAT=<ID=AD,Number=1,Type=Integer,Description="total counts for ALT">\n'
    '##FORMAT=<ID=OTH,Number=1,Type=Integer,Description="total counts for other '
    'bases from REF and ALT">\n'
    '##FORMAT=<ID=ALL,Number=5,Type=Integer,Description="total counts for all '
    'bases in order of A,C,G,T,N">\n' %__version__)
#'##FORMAT=<ID=GL,Number=G,Type=String,Description="Genotype likelihood">\n'

CONTIG = "".join(['##contig=<ID=%s>\n' %x for x in list(range(1,23))+['X', 'Y']])
header_line="#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT"

VCF_COLUMN = ["#CHROM", "POS", "ID", "REF", "ALT", "QUAL", "FILTER", 
              "INFO", "FORMAT"]

BASE_IDX = {"A": 0, "C": 1, "G": 2, "T": 3, "N": 4}
BASE_ZERO = {"A": 0, "C": 0, "G": 0, "T": 0, "N": 0}

global CACHE_CHROM
global CACHE_SAMFILE
CACHE_CHROM = None
CACHE_SAMFILE = None

def check_pysam_chrom(samFile, chrom=None):
    """Chech if samFile is a file name or pysam object, and if chrom format. 
    """
    global CACHE_CHROM
    global CACHE_SAMFILE

    if CACHE_CHROM is not None:
        if (samFile == CACHE_SAMFILE) and (chrom == CACHE_CHROM):
            return CACHE_SAMFILE, CACHE_CHROM

    if type(samFile) == str:
        ftype = samFile.split(".")[-1]
        if ftype != "bam" and ftype != "sam" and ftype != "cram" :
            print("Error: file type need suffix of bam, sam or cram.")
            sys.exit(1)
        if ftype == "cram":
            samFile = pysam.AlignmentFile(samFile, "rc")
        elif ftype == "bam":
            samFile = pysam.AlignmentFile(samFile, "rb")
        else:
            samFile = pysam.AlignmentFile(samFile, "r")

    if chrom is not None:
        if chrom not in samFile.references:
            if chrom.startswith("chr"):
                chrom = chrom.split("chr")[1]
            else:
                chrom = "chr" + chrom
        if chrom not in samFile.references:
            print("Can't find references %s in samFile" %chrom)
            return samFile, None
    
    CACHE_CHROM = chrom
    CACHE_SAMFILE = samFile
    return samFile, chrom

cdef qual_vector(qual=None, double capBQ=45, double minBQ=0.25):
    """convert the base call quality score to related values for different genotypes
    http://emea.support.illumina.com/bulletins/2016/04/fastq-files-explained.html
    https://linkinghub.elsevier.com/retrieve/pii/S0002-9297(12)00478-8

    @Note  The parameter "qual" is the qual value that is not the ASCII-encoded values typically seen in 
           FASTQ or SAM formatted files, so no need to substract 33.

    Return: a vector of loglikelihood for 
    AA, AA+AB (doublet), AB, B or E (see Demuxlet paper online methods)
    """
    if qual is None:
        return [0, 0, 0, 0]
    cdef double BQ, P
    BQ = c_max(c_min(capBQ, qual), minBQ)
    P = c_math.pow(0.1, BQ / 10.0) # Sanger coding, error probability
    RV = [c_math.log(1-P), c_math.log(3.0/4 - 2.0/3*P), c_math.log(1.0/2 - 1.0/3*P), c_math.log(P)]
    return RV


cdef qual_matrix_to_geno(qual_matrix, base_count, REF, ALT, bint doublet_GL=False):
    """
    qual_matrix: 5-by-4: ACGTN vs [1-Q, 3/4-2/3Q, 1/2-1/3Q, Q]
    base_count: (5,) for ACGTN
    
    return loglikelihood for 
        GL1: L(rr|qual_matrix, base_count), 
        GL2-GL5: L(ra|..), L(aa|..), L(rr+ra|..), L(ra+aa|..)
    """
    cdef int ref_idx = BASE_IDX[REF]
    cdef int alt_idx = BASE_IDX[ALT]
    cdef int x
    other_idx = [x for x in range(5) if "ACGTN"[x] not in [REF, ALT]]  # do not use cdef to save the overhead of initializing memoryview.

    cdef int REF_read = base_count[ref_idx]
    cdef int ALT_read = base_count[alt_idx]
    REF_qual = qual_matrix[ref_idx, :]
    ALT_qual = qual_matrix[alt_idx, :]
    cdef double OTH_qual = np.sum(qual_matrix[other_idx, 3]) + \
                            c_math.log(2.0/3) * np.sum(np.array(base_count)[other_idx])
    
    cdef double GL1 = OTH_qual + REF_qual[0] + ALT_qual[3] + c_math.log(1.0/3) * ALT_read
    cdef double GL2 = OTH_qual + REF_qual[2] + ALT_qual[2]
    cdef double GL3 = OTH_qual + REF_qual[3] + ALT_qual[0] + c_math.log(1.0/3) * REF_read
    cdef double GL4 = OTH_qual + REF_qual[1] + c_math.log(1.0/4) * ALT_read
    cdef double GL5 = OTH_qual + ALT_qual[1] + c_math.log(1.0/4) * REF_read
    if doublet_GL:
        out_GL_list = [GL1, GL2, GL3, GL4, GL5]
    else:
        out_GL_list = [GL1, GL2, GL3]

    GT_out = ["0/0", "1/0", "1/1"][np.argmax([GL1, GL2, GL3])]
    cdef double z
    cdef double y = c_math.log(10)
    PL_out = ",".join(["%.0f" % (-10 * z  / y) for z in out_GL_list])
    #GL_out = ",".join(["%.2f" %(x / np.log(10)) for x in out_GL_list])

    return GT_out, PL_out


def fetch_bases(samFile, chrom, POS, cell_tag="CR", UMI_tag="UR", min_MAPQ=20, 
                max_FLAG=255, min_LEN=30):
    """ Fetch bases from all reads mapped to a given genome position.
    Filtering is also applied, including cell and UMI tags and read mapping 
    quality.
    """
    base_list, qual_list, UMIs_list, cell_list = [], [], [], []
    if samFile is None or chrom is None or POS is None:
        if samFile is None:
            print("Warning: samFile is None")
        if chrom is None:
            print("Warning: chrom is None")
        if POS is None:
            print("Warning: POS is None")
        return base_list, qual_list, UMIs_list, cell_list

    if type(POS) != int:
        POS = int(POS)

    for _read in samFile.fetch(chrom, POS-1, POS):
        try:
            idx = _read.positions.index(POS-1)
        except:
            continue

        ## filtering reads
        if (_read.mapq < min_MAPQ or _read.flag > max_FLAG or 
            len(_read.positions) < min_LEN): 
            continue
        if cell_tag is not None and _read.has_tag(cell_tag) == False: 
            continue
        if UMI_tag is not None and _read.has_tag(UMI_tag) == False: 
            continue

        if UMI_tag is not None:
            UMIs_list.append(_read.get_tag(UMI_tag))
        if cell_tag is not None:
            cell_list.append(_read.get_tag(cell_tag))

        _base = get_query_bases(_read, full_length = False)[idx].upper()
        base_list.append(_base)
        qual_list.append(get_query_qualities(_read, full_length = False)[idx])
    return base_list, qual_list, UMIs_list, cell_list


def filter_reads(read_list, cell_tag="CR", UMI_tag="UR", min_MAPQ=20, 
                 max_FLAG=255, min_LEN=30):
    """Filter reads and check read tag, e.g., cell and UMI barcodes.
    """
    idx_keep, UMIs_list, cell_list = [], [], []
    for i in range(len(read_list)):
        _read = read_list[i]
        if (_read.mapq < min_MAPQ or _read.flag > max_FLAG or 
            len(_read.positions) < min_LEN): 
            continue
        if cell_tag is not None and _read.has_tag(cell_tag) == False: 
            continue
        if UMI_tag is not None and _read.has_tag(UMI_tag) == False: 
            continue
        if UMI_tag is not None:
            UMIs_list.append(_read.get_tag(UMI_tag))
        if cell_tag is not None:
            cell_list.append(_read.get_tag(cell_tag))
        idx_keep.append(i)
    RV = {}
    RV["idx_list"] = idx_keep
    RV["UMIs_list"] = UMIs_list
    RV["cell_list"] = cell_list
    return RV


def fetch_positions(samFile_list, chroms, positions, REF=None, ALT=None, 
                    barcodes=None, sample_ids=None, out_file=None, 
                    cell_tag="CR", UMI_tag="UR", min_COUNT=20, min_MAF=0.1, 
                    min_MAPQ=20, max_FLAG=255, min_LEN=30, doublet_GL=False, 
                    verbose=True):
    """Fetch allelic expression for a list of variants across multiple samples.
    Option 1: one single-cell sam file, a list of barcodes
    Option 2: multiple bulk sam files, multiple sample ids
    No support for multiple sam files and barcodes.
    """    
    samFile_list = [check_pysam_chrom(x, chroms[0])[0] for x in samFile_list]
    if out_file is not None:
        fid = open(out_file, "w")
        fid.writelines(VCF_HEADER + CONTIG)
        if barcodes is not None:
            fid.writelines("\t".join(VCF_COLUMN + barcodes) + "\n")
        else:
            fid.writelines("\t".join(VCF_COLUMN + sample_ids) + "\n")

    POS_CNT_TOTAL = len(positions)
    POS_CNT_NPRINTS = 50           # expected times to print the percentage of positions.
    POS_CNT_PERC_M = POS_CNT_TOTAL / POS_CNT_NPRINTS
    POS_CNT_PERC_N = POS_CNT_PERC_M
    POS_CNT = 0
    vcf_lines_all = []
    for i in range(len(positions)):
        POS_CNT += 1
        if verbose and POS_CNT_TOTAL and POS_CNT >= POS_CNT_PERC_N:
            print("%.2f%% positions processed." % (POS_CNT / POS_CNT_TOTAL * 100.0))
            POS_CNT_PERC_N += POS_CNT_PERC_M
            POS_CNT_PERC_N = POS_CNT_PERC_N if POS_CNT_PERC_N <= POS_CNT_TOTAL else POS_CNT_TOTAL
        
        base_cells_sample = []
        qual_cells_sample = []
        base_merge_sample = BASE_ZERO.copy()
        for samFile in samFile_list:
            samFile, chrom = check_pysam_chrom(samFile, chroms[i])
            base_list, qual_list, UMIs_list, cell_list = fetch_bases(samFile, 
                chrom, positions[i], cell_tag, UMI_tag, min_MAPQ, max_FLAG, 
                min_LEN)

            base_merge, base_cells, qual_cells = map_barcodes(base_list, 
                qual_list, cell_list, UMIs_list, barcodes)
            
            ### for multiple samples
            if barcodes is None:
                for _key in base_merge_sample.keys():
                    base_merge_sample[_key] += base_merge[_key]
                base_cells_sample.append(base_cells[0])
                qual_cells_sample.append(qual_cells[0])
        
        if barcodes is None:
            base_merge = base_merge_sample
            base_cells = base_cells_sample
            qual_cells = qual_cells_sample
            
        if sum(base_merge.values()) < min_COUNT:
            continue  
        
        if REF is not None and ALT is not None:
            _REF, _ALT = REF[i], ALT[i]
            #only support single nucleotide variants
            if len(_REF) > 1 or len(_ALT) > 1:
                continue
        else:
            _REF, _ALT = None, None
        vcf_line = get_vcf_line(base_merge, base_cells, qual_cells,
            chrom, positions[i], min_COUNT, min_MAF, _REF, _ALT, doublet_GL)

        if vcf_line is not None:
            if out_file is None:
                vcf_lines_all.append(vcf_line)
            else:
                fid.writelines(vcf_line)
    
    if out_file is not None:
        fid.close() 
    return vcf_lines_all


def map_barcodes(base_list, qual_list, cell_list, UMIs_list, barcodes):
    """map cell barcodes and pileup bases
    """
    base_merge = BASE_ZERO.copy()
    
    if len(base_list) == 0:
        base_cells = [[0,0,0,0,0]] # need check
        qual_cells = np.zeros((5, 4)) #ACGTN for GT (see qual_vector)
        return base_merge, base_cells, qual_cells
    
    # count UMI rather than reads
    if len(UMIs_list) == len(base_list):
        UMIs_uniq, UMIs_idx, tmp = unique_list(UMIs_list)
        base_list = [base_list[i] for i in UMIs_idx]
        qual_list = [qual_list[i] for i in UMIs_idx]
        if len(cell_list) > 0:
            cell_list = [cell_list[i] for i in UMIs_idx]
        
    if barcodes is not None and len(cell_list) > 0:
        base_cells = [[0,0,0,0,0] for x in barcodes]
        qual_cells = [np.zeros((5, 4)) for x in barcodes]
        match_idx = id_mapping(cell_list, barcodes, uniq_ref_only=False, 
                               IDs2_sorted=True)

        for i in range(len(base_list)):
            _idx = match_idx[i]
            _base = base_list[i]
            _qual = qual_list[i]
            if _idx is not None:
                base_merge[_base] += 1
                base_cells[_idx][BASE_IDX[_base]] += 1
                qual_cells[_idx][BASE_IDX[_base]] += qual_vector(_qual)
                
    else:
        qual_cells = [np.zeros((5, 4))]
        for i in range(len(base_list)):
            base_merge[base_list[i]] += 1
            qual_cells[0][BASE_IDX[base_list[i]], :] += qual_vector(qual_list[i])
        base_cells = [[base_merge[x] for x in "ACGTN"]]

    return base_merge, base_cells, qual_cells


def get_vcf_line(base_merge, base_cells, qual_cells, chrom, POS, min_COUNT, 
                 min_MAF, REF=None, ALT=None, doublet_GL=False):
    """Convert the counts for all bases into a vcf line
    """
    base_sorted = sorted(base_merge, key=base_merge.__getitem__, reverse=True)
    if REF is None or ALT is None:
        REF = base_sorted[0]
        ALT = base_sorted[1]
            
    min_cnt_2nd = min_MAF * sum(base_merge.values())      
    if (sum(base_merge.values()) < min_COUNT or 
        base_merge[base_sorted[1]] < min_cnt_2nd):
        return None

    FORMAT = "GT:AD:DP:OTH:PL:ALL"
    REF_cnt = base_merge[REF]
    ALT_cnt = base_merge[ALT]
    OTH_cnt = sum(base_merge.values()) - REF_cnt - ALT_cnt
    
    INFO = "AD=%d;DP=%d;OTH=%d" %(ALT_cnt, ALT_cnt+REF_cnt, OTH_cnt)
    
    cells_str = []
    for i in range(len(base_cells)):
        _base_cell = base_cells[i]
        _qual_cell = qual_cells[i]
        if sum(_base_cell) == 0:
            cells_str.append(".:.:.:.:.:.")
        else:
            _REF_cnt = _base_cell[BASE_IDX[REF]]
            _ALT_cnt = _base_cell[BASE_IDX[ALT]]
            _OTH_cnt = sum(_base_cell) - _REF_cnt - _ALT_cnt

            ### GT and GL
            _GT, _GL = qual_matrix_to_geno(_qual_cell, _base_cell, REF, ALT,
                                           doublet_GL = doublet_GL)
    
            all_str = ",".join([str(x) for x in _base_cell])
            cnt_lst = [str(_ALT_cnt), str(_ALT_cnt + _REF_cnt), str(_OTH_cnt)]
            out_lst = ":".join([_GT] + cnt_lst + [_GL, all_str])
            cells_str.append(out_lst)
    
    vcf_val = [chrom, str(POS), ".", REF, ALT, ".", "PASS", INFO, FORMAT]
    vcf_line = "\t".join(vcf_val + cells_str) + "\n"
    
    return vcf_line
