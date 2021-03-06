
splitRG<-function(bccount,mem){
  if(is.null(mem) || mem==0){
    maxR<- Inf
  }else{
    maxR<- floor( mem*1000 * 4500 )
  }
  if( (maxR > 2e+09 & opt$read_layout == "SE") | (maxR > 1e+09 & opt$read_layout == "PE") ){
    maxR <- ifelse(opt$read_layout == "SE",2e+09,1e+09)
  }
  if(opt$counting_opts$Ham_Dist>0){ #multicore hamming distance takes a lot of memory
    #ram_factor <- ifelse(opt$num_threads>10, 5, 2)
    ram_factor <- 2
    maxR <- floor( maxR/ram_factor )
  }

  print(paste(maxR,"Reads per chunk"))
  nc<-nrow(bccount)
  cs=0
  chunkID=1
  bccount[,chunkID:=0]
  for(i in 1:nc){
    cs=cs+bccount[i]$n
    if(bccount[i]$n>maxR){
      print(paste("Warning: Barcode",bccount[i]$XC,"has more reads than allowed for the memory limit!
                  Proceeding anyway..."))
    }
    if(cs>=maxR){
      if(i > 1){ #if the first BC exceeds the limit, keep chunkID 1
        chunkID=chunkID+1
      }
      cs=bccount[i][,"n"]
    }
    bccount[i][,"chunkID"]=chunkID
  }
  return(bccount)
}

.rmRG<-function(b){ gsub("BC:Z:","",b)  }
.rmUB<-function(b){ gsub("UB:Z:","",b)}
.rmXT<-function(b){ gsub("XT:Z:","",b)}

ham_mat <- function(umistrings) {
  X<- matrix(unlist(strsplit(umistrings, "")),ncol = length(umistrings))
  #function below thanks to Johann de Jong
  #https://goo.gl/u8RBBZ
  uniqs <- unique(as.vector(X))
  U <- X == uniqs[1]
  H <- t(U) %*% U
  for ( uniq in uniqs[-1] ) {
    U <- X == uniq
    H <- H + t(U) %*% U
  }
  nrow(X) - H
}

prep_samtools <- function(featfile,bccount,inex,cores,samtoolsexc){
  print("Extracting reads from bam file(s)...")

  nchunks <- length(unique(bccount$chunkID))
  all_rgfiles <- paste0(opt$out_dir,"/zUMIs_output/.",opt$project,".RGgroup.",1:nchunks,".txt")


  for(i in unique(bccount$chunkID)){
    rgfile <- all_rgfiles[i]
    chunks <- bccount[chunkID==i]$XC
    write.table(file=rgfile,chunks,col.names = F,quote = F,row.names = F)
  }

  if(inex){
    headerXX <- paste( c(paste0("V",1:4)) ,collapse="\t")
  }else{
    headerXX <- paste( c(paste0("V",1:3)) ,collapse="\t")
  }
  write(headerXX,"freadHeader")

  headercommand <- "cat freadHeader > "
  layoutflag <- ifelse(opt$read_layout == "PE", "-f 0x0040", "")
  samcommand <- paste(samtoolsexc," view -x QB -x QU -x BX -x NH -x AS -x nM -x HI -x IH -x NM -x uT -x MD -x jM -x jI -x XN -x XS -x UX -x ES -x EN -x IS -x IN", layoutflag, "-@")

  outfiles <- paste0(opt$out_dir,"/zUMIs_output/.",opt$project,".tmp.",1:nchunks,".txt")
  system(paste(headercommand,outfiles,collapse = "; "))

  cpusperchunk <- round(cores/nchunks,0)

  if(inex == FALSE){
    grepcommand <- " | cut -f12,13,14 | sed 's/BC:Z://' | sed 's/GE:Z://' | sed 's/UB:Z://' | grep -F -f "
    ex_cmd <- paste(samcommand,cpusperchunk,featfile,grepcommand,all_rgfiles,">>",outfiles," & ",collapse = " ")

    system(paste(ex_cmd,"wait"))
  }else{
    grepcommand <- " | cut -f12,13,14,15 | sed 's/BC:Z://' | sed 's/Z://g' | grep -F -f "
    inex_cmd <- paste(samcommand,cpusperchunk,featfile,grepcommand,all_rgfiles,">>",outfiles," & ",collapse = " ")

    system(paste(inex_cmd,"wait"))
  }
  system("rm freadHeader")
  system(paste("rm",all_rgfiles))

  return(outfiles)
}

reads2genes <- function(inex,chunkID){

  samfile <- paste0(opt$out_dir,"/zUMIs_output/.",opt$project,".tmp.",chunkID,".txt")

   if(inex==FALSE){
     reads<-data.table::fread(samfile, na.strings=c(""),
                              select=c(1,2,3),header=T,fill=T,colClasses = "character" , col.names = c("RG","GE","UB") )[
                              ,"ftype":="NA"
                              ][is.na(GE)==F,  ftype:="exon"]
  }else{
    reads<-data.table::fread(samfile, na.strings=c(""),
                             select=c(1,2,3,4),header=T,fill=T,colClasses = "character" , col.names = c("RG","V2","V3","V4") )[
                                     , V2_id := substr(V2,1,2)
                                  ][ , V3_id := substr(V3,1,2)
                                  ][ , V4_id := substr(V4,1,2)
                                  ][ , V2 := substr(V2,4,nchar(V2))
                                  ][ , V3 := substr(V3,4,nchar(V3))
                                  ][ , V4 := substr(V4,4,nchar(V4))
                                  ][ V2_id == "GE", GE := V2
                                  ][ V2_id == "GI", GEin := V2
                                  ][ V2_id == "UB", UB := V2
                                  ][ V3_id == "GE", GE := V3
                                  ][ V3_id == "GI", GEin := V3
                                  ][ V3_id == "UB", UB := V3
                                  ][ V4_id == "UB", UB := V4
                                  ][ V4_id == "GI", GEin := V4
                                  ][ ,c("V2_id","V3_id","V4_id","V2","V3","V4") := NULL
                                  ][ ,"ftype":="NA"
                                  ][is.na(GEin)==F,ftype:="intron"
                                  ][is.na(GE)==F,  ftype:="exon"
                                  ][is.na(GE),GE:=GEin
                                  ][ ,GEin:=NULL ]

  }
  system(paste("rm",samfile))

  setkey(reads,RG)

  return( reads[GE!="NA"] )
}

hammingFilter<-function(umiseq, edit=1, gbcid=NULL){
  # umiseq a vector of umis, one per read
  uc <- data.table(us = umiseq)[, .N, by = "us"] # normal UMI counts
  setorder(uc, us) #order by sequence

  if(length(uc$us)>1 && length(uc$us)<45000){ #prevent use of > 100Gb RAM
      #Sys.time()
      umi <-  ham_mat(uc$us) #construct pairwise UMI distances
      umi[upper.tri(umi,diag=T)] <- NA #remove upper triangle of the output matrix
      umi <-  data.table(
                 row = rep(seq(nrow(umi)), ncol(umi)),
                 col = rep(seq(ncol(umi)), each = nrow(umi)),
                 value = as.vector(umi)
               )[value <= edit ] #make a long data frame and filter according to cutoff
      umi[, "n.1" := uc[row]$N ][
          , "n.2" := uc[col]$N ] #add in observed freq

      umi_out <- copy(umi)
      if(nrow(umi_out) == 0){
        return(umi_out)
      }

      umi_out        [, falseUMI := ifelse( n.1>n.2, col, row ) ][
                       , trueUMI := ifelse( n.1<n.2, col, row ) ][
                       , n.false := ifelse( n.1>n.2, n.2, n.1 )][
                       , n.true := ifelse( n.1<n.2, n.2, n.1 )][
                       , falseUMI := uc[falseUMI]$us ][
                       , trueUMI  := uc[trueUMI ]$us][
                       , BC := tstrsplit(gbcid, "_", keep = 1)][
                       , GE := substr(x = gbcid, start = (nchar(BC)+2), stop = nchar(gbcid))][
                       #, c("BC","GE") := tstrsplit(gbcid, "_") ][ #can break in case of underscore in geneID!
                       , c("row", "col", "value", "n.1", "n.2") := NULL]
      umi_out <- umi_out[!falseUMI == trueUMI]

      dup_daughters <- unique(umi_out[which(duplicated(falseUMI))]$falseUMI)
      if(length(dup_daughters>0)){
        umi_out[,rem := FALSE]
        setorder(umi_out, falseUMI, -n.true)
        setkey(umi_out, falseUMI)
        for(i in dup_daughters){
            umi_out[ i, rem := TRUE ] #remove duplicates
            umi_out[ i, mult = "first" , rem := FALSE] # keep the most frequent parent UMI
          }
        umi_out <- umi_out[rem == FALSE]
        umi_out[, rem := NULL]
      }


      non_true_UMIs <- unique(umi_out[trueUMI %in% umi_out$falseUMI]$trueUMI)
      real_true_UMIs <- unique(umi_out[!trueUMI %in% umi_out$falseUMI]$trueUMI)
      if(length(non_true_UMIs>0)){
        setkey(umi_out, falseUMI)
        for(i in non_true_UMIs){
          true_parent_UMI <- umi_out[i][!trueUMI %in% non_true_UMIs]$trueUMI
          if(length(true_parent_UMI)==0){#find closest match in case there is no clear parent UMI!
            true_parent_UMI <- real_true_UMIs[stringdist::amatch(umi_out[i][1]$trueUMI, real_true_UMIs, method = "hamming", maxDist=edit)[1]]
          }
          if(length(true_parent_UMI)>1){ #take a random good parent UMI if more possibilities exist
            true_parent_UMI <- true_parent_UMI[1]
          }
          umi_out[trueUMI == i, trueUMI := true_parent_UMI]
        }
      }
      umi_out[,dist := stringdist::stringdist(falseUMI,trueUMI,method = "hamming")]
      umi_out <- umi_out[dist <= edit]
      umi_out[, c("n.false","n.true","dist") := NULL]
      return(umi_out)


  }else{
    return(NULL)
  }
}

ham_helper_fun <- function(x){
    x[, gbcid := paste(RG,GE,sep="_")]
    x_list <- split(x = x, drop = T, by = c("gbcid"), sorted = T, keep.by = T)
    out_list <- lapply(x_list, function(x) hammingFilter(x[!is.na(UB)]$UB, edit=opt$counting_opts$Ham_Dist, gbcid=unique(x$gbcid)) )
    elements_keep <- which(unlist(lapply(out_list, function(x) nrow(x))) > 0 )
    out_list <- out_list[names(elements_keep)]
    outdf <- rbindlist(out_list)
    return(outdf)
}

.sampleReads4collapsing<-function(reads,bccount,nmin=0,nmax=Inf,ft){
  #filter reads by ftype and get bc-wise exon counts
  #join bc-wise total counts
  rcl<-reads[ftype %in% ft][bccount ,nomatch=0][  n>=nmin ] #
  if(nrow(rcl)>0)  {
    return( rcl[ unlist(rcl[ ,exn:=.N,by=RG
                           ][         , targetN:=exn  # use binomial to break down to exon sampling
                                      ][ n> nmax, targetN:=rbinom(1,nmax,mean(exn)/mean(n) ), by=RG
                                      ][targetN>exn, targetN:=exn][is.na(targetN),targetN :=0
                                                                 ][ ,list(list(sample(.I , targetN))),by = RG]$V1) ])
  }else{ return(NULL) }
}

.makewide <- function(longdf,type){
  ge<-as.factor(longdf$GE)
  xc<-as.factor(longdf$RG)
  widedf <- Matrix::sparseMatrix(i=as.integer(ge),
                                 j=as.integer(xc),
                                 x=as.numeric(unlist(longdf[,type,with=F])),
                                 dimnames=list(levels(ge), levels(xc)))
  return(widedf)
}

umiCollapseID<-function(reads,bccount,nmin=0,nmax=Inf,ftype=c("intron","exon"),...){
  retDF<-.sampleReads4collapsing(reads,bccount,nmin,nmax,ftype)
  if(!is.null(retDF)){
    nret<-retDF[, list(umicount = length(unique(UB[!is.na(UB) & UB!=""])),
                       readcount =.N),
                by=c("RG","GE") ]

    nreads <- nrow(retDF)
    n_nonUMI <- nrow(retDF[!is.na(UB)][!UB == ""])
    if(n_nonUMI > 0 & n_nonUMI<nreads){ #detect mix of internal and UMI reads in Smartseq3
      internaldt <- retDF[UB=="", list(readcount_internal =.N),
                         by=c("RG","GE") ]
      nret <- merge(nret, internaldt, by = c("RG","GE"), all.x = TRUE)
      nret[is.na(readcount_internal), readcount_internal := 0]
    }

    return(nret)
  }
}
umiCollapseHam<-function(reads,bccount,HamDist=1){
  #library(foreach)
  library(parallel)
  library(dplyr)
  readsamples <- reads
  setkey(readsamples,RG)
  print("Splitting data for multicore hamming distance collapse...")
  readsamples_list <- split(x = readsamples, drop = T, by = c("RG"), sorted = T, keep.by = T)
  print("Setting up multicore cluster & generating molecule mapping tables ...")
  #this step is ram hungry, try to not go overboard too much:
  max_cores <- ceiling(opt$mem_limit/5)
  if(max_cores < opt$num_threads){
    use_cores <- max_cores
  }else{
    use_cores <- opt$num_threads
  }
  #run:
  out_mm <- mclapply(readsamples_list, function(x) ham_helper_fun(x), mc.cores = use_cores, mc.preschedule = TRUE)
  out_mm <- rbindlist(out_mm)
  write_molecule_mapping(out_mm)

  print("Finished multi-threaded hamming distances")
  gc(verbose = F)
}

umiFUNs<-list(umiCollapseID=umiCollapseID,  umiCollapseHam=umiCollapseHam)

check_nonUMIcollapse <- function(seqfiles){
  #decide wether to run in UMI or no-UMI mode
  UMI_check <- lapply(seqfiles,
                      function(x) {
                        if(!is.null(x$base_definition)) {
                          if(any(grepl("^UMI",x$base_definition))) return("UMI method detected.")
                        }
                      })

  umi_decision <- ifelse(length(unlist(UMI_check))>0,"UMI","nonUMI")
  return(umi_decision)
}

collectCounts<-function(reads,bccount,subsample.splits, mapList, ...){
  subNames<-paste("downsampled",rownames(subsample.splits),sep="_")
  umiFUN<-"umiCollapseID"
  lapply(mapList,function(tt){
    ll<-list( all=umiFUNs[[umiFUN]](reads=reads,
                                bccount=bccount,
                                ftype=tt),
              downsampling=lapply( 1:nrow(subsample.splits) , function(i){
                umiFUNs[[umiFUN]](reads,bccount,
                                  nmin=subsample.splits[i,1],
                                  nmax=subsample.splits[i,2],
                                  ftype=tt)} )
    )
    names(ll$downsampling)<-subNames
    ll
  })

}

bindList<-function(alldt,newdt){
  for( i in names(alldt)){
    alldt[[i]][[1]]<-rbind(alldt[[i]][[1]], newdt[[i]][[1]] )
    for(j in names(alldt[[i]][[2]])){
      alldt[[i]][[2]][[j]]<-rbind(alldt[[i]][[2]][[j]],newdt[[i]][[2]][[j]])
    }
  }
  return(alldt)
}

convert2countM<-function(alldt,what){
  fmat<-alldt
  for( i in 1:length(alldt)){
    fmat[[i]][[1]]<-.makewide(alldt[[i]][[1]],what)
    for(j in names(alldt[[i]][[2]])){
      fmat[[i]][[2]][[j]]<-.makewide(alldt[[i]][[2]][[j]],what)
    }
  }
  return(fmat)
}

write_molecule_mapping <- function(mm){
  mm_path <- paste0(opt$out_dir,"/zUMIs_output/molecule_mapping/")
  bcs <- unique(mm$BC)
  for(i in bcs){
    data.table::fwrite(mm[BC == i], file = paste0(mm_path,opt$project,".",i,".txt"), quote = F, sep = "\t")
  }
}

correct_UB_tags <- function(bccount, samtoolsexc){
  mm_path <- paste0(opt$out_dir,"/zUMIs_output/molecule_mapping/")
  demux_path <- paste0(opt$out_dir,"/zUMIs_output/demultiplexed/")
  UB_cmd_list <- list()
  for(i in bccount$XC){
    bam <- paste0(demux_path,opt$project,".",i,".demx.bam")
    bamout <- paste0(demux_path,opt$project,".",i,".demx.UBcorrected.bam")
    mm <- paste0(mm_path,opt$project,".",i,".txt")
    pl_path <- paste0(opt$zUMIs_directory,"/correct_UBtag.pl")
    UB_cmd <- paste(pl_path,bam,bamout,mm,samtoolsexc)
    UB_cmd_list[[i]] <- UB_cmd
  }
  bla <- parallel::mclapply(UB_cmd_list, system, ignore.stderr = TRUE, mc.cores = opt$num_threads, mc.preschedule=F, mc.silent = TRUE)
  UB_cmd_list <- unlist(UB_cmd_list)
  UB_files <- as.character(data.frame(strsplit(UB_cmd_list," "),stringsAsFactors=F)[3,])
  #UB_files <- paste(UB_files, collapse = " ")
  UB_mergelist <- paste0(opt$out_dir,"/zUMIs_output/molecule_mapping/",opt$project,"mergelist.txt")
  write(UB_files, file = UB_mergelist)
  outbam <- paste0(opt$out_dir,"/",opt$project,".filtered.Aligned.GeneTagged.UBcorrected.bam")
  #merge_cmd <- paste(samtoolsexc,"merge -n -t BC -@",opt$num_threads,"-b",UB_mergelist,outbam)
  merge_cmd <- paste(samtoolsexc,"cat -b",UB_mergelist,"-o",outbam)
  write(merge_cmd, file = paste0(opt$out_dir,"/",opt$project,".merge.sh"))
  system(paste0("bash ",opt$out_dir,"/",opt$project,".merge.sh"))
  return(outbam)
}

demultiplex_bam <- function(opt, bamfile, nBCs){
  if(!dir.exists( paste0(opt$out_dir,"/zUMIs_output/demultiplexed/") )){
    dir.create( paste0(opt$out_dir,"/zUMIs_output/demultiplexed/") )
  }

  installed_py <- system("pip freeze", intern = TRUE)

  if(any(grepl("pysam==",installed_py))){
    print("Using python implementation to demultiplex.")
    print(Sys.time())
    max_filehandles <- as.numeric(system("ulimit -n", intern = TRUE))
    threads_perBC <- floor(max_filehandles/nBCs)
    
    if(max_filehandles < nBCs | nBCs > 10000){
      #print("Warning! You cannot open enough filehandles for demultiplexing! Increase ulimit -n")
      #break up in several demultiplexing runs to avoid choke
      nchunks <- ifelse(max_filehandles < nBCs, no = ceiling(nBCs/10000), yes = ceiling(nBCs/(max_filehandles-100)))
      if(nchunks == 1){nchunks = 2}
      print(paste("Breaking up demultiplexing in",nchunks,"chunks. This may be because you have >10000 cells or a too low filehandle limit (ulimit -n)."))
      
      full_bclist <- paste0(opt$out_dir,"/zUMIs_output/",opt$project,"kept_barcodes.txt")
      bcsplit_prefix <- paste0(opt$out_dir,"/zUMIs_output/.",opt$project,"kept_barcodes.")
      
      split_cmd <- paste0("split -a 3 -n l/",nchunks," ",full_bclist, " ", bcsplit_prefix)
      system(split_cmd)
      bclist <- list.files(path = paste0(opt$out_dir,"/zUMIs_output/"), pattern =  paste0(".",opt$project,"kept_barcodes."),all.files = TRUE, full.names = TRUE)
      header_cmd <- paste('sed -i -e \'1s/^/XC,n,cellindex\\n/\'', bclist[-1], collapse = '; ', sep = ' ')
      system(header_cmd)
      
      if(max_filehandles < nBCs){threads_perBC <- 1}
    }else{
      bclist <- paste0(opt$out_dir,"/zUMIs_output/",opt$project,"kept_barcodes.txt")
    }
    
    if(threads_perBC > 2){
      threads_perBC <- 2
    }
    threads_decompress <- opt$num_threads - threads_perBC
    outstub <- paste0(opt$out_dir,"/zUMIs_output/demultiplexed/",opt$project,".")
    py_script <- paste0(opt$zUMIs_directory,"/misc/demultiplex_BC.py")
    demux_cmd <- paste(
      "python3", py_script,
      "--bam", bamfile,
      "--out", outstub,
      "--bc", bclist,
      "--pout", threads_perBC,
      "--pin", threads_decompress
    , collapse = "; ")
  }else{
    print("Using perl implementation to demultiplex.")
    demux_cmd <- paste0(opt$zUMIs_directory,"/misc/demultiplex_BC.pl ",opt$out_dir," ",opt$project, " ", bamfile, " ", samtoolsexc )
  }
  system(demux_cmd)
  print(Sys.time())
}

split_bam <- function(bam, cpu, samtoolsexc){
  UMIbam <- paste0(bam,".UMI.bam")
  internalbam <- paste0(bam,".internal.bam")
  cpus <- floor((cpu-4)/2)
  if(cpus<1){
    cpus <- 2
  }
  
  cmd_umi <- paste(samtoolsexc, "view -h -@ 2", bam, " | grep -v -P 'UB:Z:\t' | ", samtoolsexc, "view -b -@",cpus,"-o",UMIbam,"&")
  cmd_internal <- paste(samtoolsexc, "view -h -@ 2", bam, " | grep -v 'UB:Z:[A-Z]' | ", samtoolsexc, "view -b -@",cpus,"-o",internalbam,"&")
  system(paste(cmd_umi,cmd_internal,"wait"))
  return(c(internalbam,UMIbam))
}

fixMissingOptions <- function(config){
  if(is.null(config$barcodes$automatic)){
    if(is.null(config$barcodes$barcode_num) & is.null(config$barcodes$barcode_file)){
      config$barcodes$automatic <- TRUE
    }else{
      config$barcodes$automatic <- FALSE
    }
  }

  if(is.null(config$barcodes$BarcodeBinning)){
    config$barcodes$BarcodeBinning <- 0
  }
  if(is.null(config$barcodes$nReadsperCell)){
    config$barcodes$nReadsperCell <- 100
  }

  if(is.null(config$barcodes$demultiplex)){
    config$barcodes$demultiplex <- FALSE
  }

  if(is.null(config$counting_opts$introns)){
    config$counting_opts$introns <- TRUE
  }

  if(is.null(config$counting_opts$primaryHit)){
    config$counting_opts$primaryHit <- TRUE
  }

  if(is.null(config$counting_opts$strand)){
    config$counting_opts$strand <- 0
  }

  if(is.null(config$counting_opts$Ham_Dist)){
    config$counting_opts$Ham_Dist <- 0
  }

  if(is.null(config$counting_opts$velocyto)){
    config$counting_opts$velocyto <- FALSE
  }

  if(is.null(config$counting_opts$write_ham)){
    config$counting_opts$write_ham <- FALSE
  }

  if(is.null(config$counting_opts$downsampling)){
    config$counting_opts$downsampling <- "0"
  }

  if(config$counting_opts$downsampling == FALSE){
    config$counting_opts$downsampling <- "0"
  }
  
  return(config)
}

RPKM.calc <- function(exprmat, gene.length){
  x <- as.matrix(exprmat)
  gene.length <- gene.length[match(row.names(x),GeneID)]$tx_bp
  gene.length.kb <- gene.length / 1000

  lib.size <- 1e-6*colSums(x)
  y <- t(t(x)/lib.size)
  y/gene.length.kb
}
