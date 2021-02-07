import pandas as pd
from os.path import join

configfile: 'config.yaml'

samples = pd.read_table(config['samples']).set_index('sample')

rule all:
    input:
        expand("output/trimmed/{sample}.qc.txt",
               sample=samples.index),
        expand("output/filtered/{sample}.{read}.fastq.gz",
               sample=samples.index,
               read=[1,2]),
        "output/qc/multiqc.html",
        expand("output/function/{sample}_genefamilies.tsv",
               sample=samples.index)


rule pre_fastqc_fwd:
    input:
        lambda wildcards: samples.loc[wildcards.sample,
                                      'fq1']
    output:
        html="output/qc/fastqc/{sample}.R1.html",
        zip="output/qc/fastqc/{sample}.R1_fastqc.zip" 
        # the suffix _fastqc.zip is necessary for multiqc to find the file.
        # If not using multiqc, you are free to choose an arbitrary filename
    params: ""
    log:
        "output/logs/fastqc/{sample}.R1.log"
    threads: 1
    wrapper:
        "0.70.0/bio/fastqc"

rule pre_fastqc_rev:
    input:
        lambda wildcards: samples.loc[wildcards.sample,
                                      'fq2']
    output:
        html="output/qc/fastqc/{sample}.R2.html",
        zip="output/qc/fastqc/{sample}.R2_fastqc.zip"
        # the suffix _fastqc.zip is necessary for multiqc to find the file.
        # If not using multiqc, you are free to choose an arbitrary filename
    params: ""
    log:
        "output/logs/fastqc/{sample}.R2.log"
    threads: 1
    wrapper:
        "0.70.0/bio/fastqc"

rule cutadapt_pe:
    input:
        lambda wildcards: samples.loc[wildcards.sample,
                                      'fq1'],
        lambda wildcards: samples.loc[wildcards.sample,
                                      'fq2']
    output:
        fastq1="output/trimmed/{sample}.1.fastq.gz",
        fastq2="output/trimmed/{sample}.2.fastq.gz",
        qc="output/trimmed/{sample}.qc.txt"
    params:
        "-a {} {}".format(config["trimming"]["adapter"],
                          config["params"]["cutadapt-pe"])
    log:
        "output/logs/cutadapt/{sample}.log"
    wrapper:
        "0.17.4/bio/cutadapt/pe"


rule host_filter:
    """
    Performs host read filtering on paired end data using Bowtie and Samtools/
    BEDtools. Takes the four output files generated by Trimmomatic. 

    Also requires an indexed reference (path specified in config). 

    First, uses Bowtie output piped through Samtools to only retain read pairs
    that are never mapped (either concordantly or just singly) to the indexed
    reference genome. Fastqs from this are gzipped into matched forward and 
    reverse pairs. 

    Unpaired forward and reverse reads are simply run through Bowtie and
    non-mapping gzipped reads output.

    All piped output first written to localscratch to avoid tying up filesystem.
    """
    input:
        fastq1="output/trimmed/{sample}.1.fastq.gz",
        fastq2="output/trimmed/{sample}.2.fastq.gz"
    output:
        fastq1="output/filtered/{sample}.1.fastq.gz",
        fastq2="output/filtered/{sample}.2.fastq.gz",
        temp_dir=temp(directory("output/filtered/{sample}_temp"))
    params:
        ref=config['host_reference']
    conda:
        "envs/bowtie2.yaml"
    threads:
        config['threads']['host_filter']
    log:
        bowtie = "output/logs/bowtie2/sample_{sample}.bowtie.log",
        other = "output/logs/bowtie2/sample_{sample}.other.log"
    shell:
        """
        # Make temporary output directory
        mkdir -p {output.temp_dir}

        # Map reads against reference genome, and separate all read pairs
        # that map at least once to the reference, even discordantly.
        bowtie2 -p {threads} -x {params.ref} --very-sensitive \
          -1 {input.fastq1} -2 {input.fastq2} \
          2> {log.bowtie} | \
          samtools view -f 12 -F 256 -b \
          -o {output.temp_dir}/{wildcards.sample}.unsorted.bam \
          2> {log.other} 

        # Sort the resulting alignment
        samtools sort -T {output.temp_dir}/{wildcards.sample} \
          -@ {threads} -n \
          -o {output.temp_dir}/{wildcards.sample}.bam \
          {output.temp_dir}/{wildcards.sample}.unsorted.bam \
          2> {log.other} 

        # Convert sorted alignment to fastq format
        bedtools bamtofastq -i {output.temp_dir}/{wildcards.sample}.bam \
          -fq {output.temp_dir}/{wildcards.sample}.R1.trimmed.filtered.fastq \
          -fq2 {output.temp_dir}/{wildcards.sample}.R2.trimmed.filtered.fastq \
          2> {log.other}

        # zip the filtered fastqs
        pigz -p {threads} \
          -c {output.temp_dir}/{wildcards.sample}.R1.trimmed.filtered.fastq > \
          {output.temp_dir}/{wildcards.sample}.R1.trimmed.filtered.fastq.gz
        pigz -p {threads} \
          -c {output.temp_dir}/{wildcards.sample}.R2.trimmed.filtered.fastq > \
          {output.temp_dir}/{wildcards.sample}.R2.trimmed.filtered.fastq.gz

        # copy the filtered fastqs to final location
        cp {output.temp_dir}/{wildcards.sample}.R1.trimmed.filtered.fastq.gz \
          {output.fastq1}
        cp {output.temp_dir}/{wildcards.sample}.R2.trimmed.filtered.fastq.gz \
          {output.fastq2}
        """


rule multiqc:
    """
    Runs MultiQC to aggregate all the information from FastQC, adapter
    trimming, and host filtering.
    """
    input:
        lambda wildcards: expand(rules.pre_fastqc_rev.output,
                                 sample=samples.index),
        lambda wildcards: expand(rules.pre_fastqc_fwd.output,
                                 sample=samples.index),
        lambda wildcards: expand(rules.cutadapt_pe.output,
                                 sample=samples.index),
        lambda wildcards: expand(rules.host_filter.log.bowtie,
                                 sample=samples.index)

    output:
        "output/qc/multiqc.html"
    params:
        ""  # Optional: extra parameters for multiqc.
    log:
        "output/logs/multiqc.log"
    wrapper:
        "0.70.0/bio/multiqc"


rule metaphlan3_setup:
    """
    Installs MetaPhlAn3 databases.

    Set desired db location in config.yaml.

    If using a pre-existing database, you should add an empty file in the
    db directory called 'metaphlan3.done' so Snakemake knows it doesn't need
    to re-download it.
    """
    input:
    output:
        done=touch(join(config['metaphlan3']['db_loc'],
              'metaphlan3.done'))
    conda:
        "envs/metaphlan3.yaml"
    log:
        "output/logs/metaphlan3_setup.log"
    params:
        db_loc=config['metaphlan3']['db_loc']
    shell:
        "metaphlan --install --bowtie2db {params.db_loc}"


rule metaphlan3:
    input:
        db=rules.metaphlan3_setup.output.done,
        fastq1="output/filtered/{sample}.1.fastq.gz",
        fastq2="output/filtered/{sample}.2.fastq.gz",
    output:
        bowtie2="output/taxonomy/{sample}.metaphlan.bowtie2.bz2",
        profile="output/taxonomy/{sample}.metaphlan.txt"
    conda:
        "envs/metaphlan3.yaml"
    log:
        "output/logs/metaphlan/{sample}.metaphlan.log"
    threads:
        config['threads']['metaphlan3']
    params:
        db_loc=config['metaphlan3']['db_loc']
    shell:
        """
        metaphlan {input.fastq1},{input.fastq2} \
          --bowtie2db {params.db_loc} \
          --bowtie2out {output.bowtie2} \
          --nproc {threads} \
          --input_type fastq \
          -o {output.profile} \
          2> {log}
        """


rule combine_metaphlan:
    """
    Combines individual sample MetaPhlAn bug lists into a single aggregate
    file to give to HUMAnN3. This allows you to use the same nucleotide
    database for all samples. 
    """
    input:
        expand("output/taxonomy/{sample}.metaphlan.txt",
               sample=samples.index)
    output:
        "output/taxonomy/combined.metaphlan.txt"
    conda:
        "envs/metaphlan3.yaml"
    log:
        "output/logs/metaphlan/combined.metaphlan.log"
    threads:
        1
    shell:
        """
        merge_metaphlan_tables.py \
          {input} > {output} 2> {log}
        """

rule humann_setup:
    """
    Installs HUMAnN3 databases.

    Set desired db locations in config.yaml.

    If using pre-existing databases, you should add empty files in the
    db directory called 'chocophlan_dl.done' and 'uniref_dl.done' to let
    Snakemake know that it doesn't need to download them again.
    """
    input:
    output:
        choco_done=touch(join(config['humann3']['db_loc'],
                              "chocophlan_dl.done")),
        uniref_done=touch(join(config['humann3']['db_loc'],
                               "uniref_dl.done")),
        choco_db=join(config['humann3']['db_loc'], "chocophlan"),
        uniref_db=join(config['humann3']['db_loc'], "uniref")
    conda:
        "envs/humann3.yaml"
    log:
        "output/logs/humann3/humann_setup.log"
    params:
        choco_db=config['humann3']['choco_db'],
        uniref_db=config['humann3']['uniref_db'],
        db_loc=config['humann3']['db_loc']
    shell:
        """
        mkdir -p {params.db_loc}
        humann_databases --download chocophlan {params.choco_db} \
          {params.db_loc} 2> {log}
        humann_databases --download uniref {params.uniref_db} \
          {params.db_loc} 2>> {log}
        """

rule humann3:
    input:
        choco_db=rules.humann_setup.output.choco_db,
        uniref_db=rules.humann_setup.output.uniref_db,
        metaphlan=rules.combine_metaphlan.output,
        fastq1="output/filtered/{sample}.1.fastq.gz",
        fastq2="output/filtered/{sample}.2.fastq.gz"
    output:
        temp_dir=temp(directory("output/function/{sample}_temp")),
        genefam="output/function/{sample}_genefamilies.tsv",
        pathcov="output/function/{sample}_pathcoverage.tsv",
        pathabn="output/function/{sample}_pathabundance.tsv"
    conda:
        "envs/humann3.yaml"
    log:
        "output/logs/humann3/{sample}_humann.log"
    params:
        humann3=config['params']['humann3']
    threads:
        config['threads']['humann3']
    shell:
        """
        mkdir -p {output.temp_dir}

        cat {input.fastq1} {input.fastq2} > {output.temp_dir}/{wildcards.sample}.fastq.gz

        humann \
        --threads {threads} \
        --bypass-prescreen \
        --taxonomic-profile {input.metaphlan} \
        --nucleotide-database  {input.choco_db} \
        --protein-database {input.uniref_db} \
        --output-basename {wildcards.sample} \
        --input {output.temp_dir}/{wildcards.sample}.fastq.gz \
        --output {output.temp_dir} \
        {params.humann3} \
        2> {log}

        cp {output.temp_dir}/{wildcards.sample}_genefamilies.tsv {output.genefam}
        cp {output.temp_dir}/{wildcards.sample}_pathcoverage.tsv {output.pathcov}
        cp {output.temp_dir}/{wildcards.sample}_pathabundance.tsv {output.pathabn}
        """

