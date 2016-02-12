library(gtools)
library(shiny)
library(shinyFiles)
library(rhdf5)
library(SparseM)
library(ggplot2)

shinyServer(function(input, output, session) {
  
  # --------------------
  # Setup/Load Data Page
  # --------------------
  # Use shinyFiles library for selecting local files
  # The built-in fileInput copies the file -- not necessary
  shinyFileChoose(input, 'timeseries_database', root=c(home='~'), filetypes=c('h5'), session=session)
  
  output$tst_filename <- renderPrint({
    if (is.null(input$timeseries_database))
      return("Please select your time-series database file")
    as.character(parseFilePaths(c(home='~'), input$timeseries_database)$datapath[1])
  })

  # Declare some variables here so we can viciously abuse R's scoping
  # In the future, I should figure out if Shiny can handle this properly
  # because this has gotten a bit out of hand
  max_cluster <- NULL
  min_param <- NULL
  step_size <- NULL
  taxonomic_ids <- NULL
  sequence_ids <- NULL
  sequencecluster_labels <- NULL
  tp <- NULL
  modCRTLIST <- NULL
  tsdatabase_path <- NULL
  nsequences <- NULL
  nsamples <- NULL
  nparams <- NULL
  current_clusters <- NULL
  timeseries_table <- NULL
  timeseries_totals <- NULL
  cluster_names <- NULL
  
  loadFilesResult <- observeEvent(input$loadFiles, {
    withProgress(message = 'Loading database file, please wait...', value = 0, {
      tsdatabase_path <<- normalizePath(as.character(parseFilePaths(c(home='~'), input$timeseries_database)$datapath[1]))
      #First, load the cluster file
      
      h5data <- h5ls(tsdatabase_path)
      nsequences <<- as.numeric(h5data[h5data$name=="sequenceids",]$dim)
      nsamples <<- as.numeric(h5data[h5data$name=="names",]$dim)
      nparams <<- as.numeric(strsplit(h5data[h5data$name=="clusters",]$dim,' x')[[1]][1])
      incProgress(0.1, detail = "Reticulating splines...")
      #Time cluster labels loaded on the fly
      #Time-series table
      tslength<-as.numeric(h5data[h5data$name=="data",]$dim)
      tsdata<-vector(length=tslength)
      #Small enough to read in one go
      tsindptr<-h5read(tsdatabase_path,"timeseries/indptr")
      incProgress(0.25, detail = "De-chunking time dimension...")
      #The time-series data must be read in chunks to prevent huge memory
      #usage by the HDF5 library
      tsdata<-vector(length=tslength)
      tsindices<-vector(length=tslength)
      chunks<-seq(1,tslength,10000)
      #Make sure we get all the chunks
      if (chunks[length(chunks)] != tslength) {
        chunks<-c(chunks,tslength)
      }
      for (i in 1:(length(chunks)-1)){
        tsdata[chunks[i]:chunks[i+1]] <- h5read(tsdatabase_path,
             "timeseries/data",index=list(chunks[i]:chunks[i+1]))
        tsindices[chunks[i]:chunks[i+1]] <- h5read(tsdatabase_path,
             "timeseries/indices",index=list(chunks[i]:chunks[i+1]))
      }
      #Correct for R's 1-based indexing
      tsindices <- tsindices+1
      tsindptr <- tsindptr+1
      #Make a sparse matrix, immediately converting it to a full matrix
      #This is necessary because the sparse classes can't do everything
      #that the full class can do
      timeseries_table <<- as.matrix(new("matrix.csr",ra=as.numeric(tsdata),
                 ja=as.integer(tsindices),ia=as.integer(tsindptr),
                 dimension=as.integer(c(nsequences,nsamples))))
      timeseries_totals <<- colSums(timeseries_table)
      incProgress(0.5, detail="Identifying life-forms...")
      #Read in auxiliary information
      taxonomic_ids <<- h5read(tsdatabase_path, "genes/taxonomy")
      sequencecluster_labels <<- h5read(tsdatabase_path, "genes/sequenceclusters")
      sequence_ids <<- h5read(tsdatabase_path, "genes/sequenceids")
      #Grab some of the required numbers
      incProgress(0.75, detail="Uploading mission parameters...")
      tp <<- h5read(tsdatabase_path,"samples/time")
      cluster_params <- h5readAttributes(tsdatabase_path,"genes/clusters")
      min_param <<- cluster_params$param_min
      max_param <<- cluster_params$param_max
      step_size <<- cluster_params$param_step
      incProgress(1, detail="Triangulation complete.")
    })
  })
  
  output$tsdb_filename <- renderText({
    if (is.null(input$timeseries_database)) {
        "Please select a file"
    } else {
      normalizePath(as.character(parseFilePaths(c(home='~'), input$timeseries_database)$datapath[1]))
    }
  })
  
  # --------------------
  # Data Summary Page
  # --------------------
  
  #Plot the number of clusters vs epsilon
  nclusters <- eventReactive(input$plotnclust, {
    withProgress(message = 'Retrieving clusters from database file...', value = 0, {
      nclusts <- c()
      for (i in 1:nparams) {
        incProgress(i/nparams)
        clusts <- h5read(tsdatabase_path,"genes/clusters",index=list(i,NULL))
        nclusts <- c(nclusts, length(unique(t(clusts))))
      }
      nclusts
    })
  })
  
  output$clusterVsEps <- renderPlot({
      params <- 0:(nparams-1)*step_size+min_param
      plot(params,nclusters(),type='l')
  })
  
  #Simpson Index (list items must be proportions)
  Simpson <- function(x) Reduce("+", x^2)
  
  tax_consistency <- eventReactive(input$plottemptaxconsist, {
      tax_levels <- c("Kingdom","Phylum","Class","Order","Family","Genus","Species")
      short_code <- c("k__","p__","c__","o__","f__","g__","s__")
      taxdf <- data.frame()
      for (level in 2:7) {
      simpson_indices <- c()
      for (clusterid in unique(current_clusters)) {
        if (clusterid != "-1") {
          tax_ids <- taxonomic_ids[current_clusters==clusterid]
          split_tax<- sapply(tax_ids,function(x) strsplit(x,";")[[1]][level])
          taxtable <- table(as.factor(split_tax))
          taxtable <- taxtable[rownames(taxtable!=short_code[level])]
          proptaxtable <- taxtable/sum(taxtable)
          simpson_index <- Simpson(proptaxtable)
          #Simpson index may be NULL if table is empty
          #(i.e., no classifications at level)
          if (!is.null(simpson_index))
            simpson_indices <- c(simpson_indices, simpson_index)
        }
      }
          taxdf <- rbind(taxdf,
                         data.frame(values=simpson_indices,
                         level=rep(tax_levels[level], length(simpson_indices))))
      }
      taxdf
  })
      
  output$temptaxconsist <- renderPlot({
      #Plotting temporal taxonomic consistency
      p<-ggplot(tax_consistency(), aes(y=values, x=level))                                                         
      p+geom_boxplot()
  })
  
  # --------------------
  # Explore Clusters Page
  # --------------------
  
  #Populate the current_clusters variable with the cluster names for
  #the given clustering parameter
  changeClusterResult <- observeEvent(input$cluster_param, {
    cluster_index <- (input$cluster_param-min_param)/step_size+1
    current_clusters <<- as.vector(h5read(tsdatabase_path,"genes/clusters",index=list(cluster_index,1:nsequences)))
  }, ignoreNULL = TRUE)
  
  #Slider for selecting epsilon parameter
  output$clusterParamSelector <- renderUI({
    numericInput("cluster_param", "Cluster parameter (eps):", 
                 min = min_param, max = max_param, step = step_size, value = min_param)
  })
  
  output$plotConsistButton <- renderUI({
      if (is.null(input$cluster_param))
        return()
      actionButton("plottemptaxconsist",paste("Plot Temporal/Taxonomic Consistency for Epsilon =",input$cluster_param))
  })
  
  #Select time series cluster widget
  output$clusterSelector <- renderUI({
    if (is.null(input$cluster_param))
      return()
    cluster_abunds <- aggregate(rowSums(timeseries_table), by=list(current_clusters), FUN=sum)
    cluster_names <- as.numeric(cluster_abunds[order(cluster_abunds[,2], decreasing=TRUE),1])
    if ((length(cluster_names) > 1) & (cluster_names[1] == -1)) {
        select <- cluster_names[2]
    } else {
        select <- cluster_names[1]
    }
    selectInput('cluster_number', 'Cluster number:', choices = cluster_names,
                multiple = FALSE, selectize = FALSE, selected = select)
  })
  
  #Select OTU number widget
  output$OTUSelector <- renderUI({
    cluster_abunds <- aggregate(rowSums(timeseries_table), by=list(sequencecluster_labels), FUN=sum)
    cluster_names <- as.numeric(cluster_abunds[order(cluster_abunds[,2], decreasing=TRUE),1])
    select <- cluster_names[1]
    selectInput('otu_number', 'OTU Cluster number:', choices = cluster_names,
                multiple = FALSE, selectize = FALSE, selected = select)
  })

  #Main time series cluster plot
  output$main_plot <- renderPlot({
    if (is.null(input$cluster_param))
      return()
    if (is.null(input$cluster_number))
      return()
    # Take only the time-series that are in the current cluster
    subset_table <- timeseries_table[current_clusters==input$cluster_number, ]
    # Make a normalized version
    norm_subset_table <- subset_table/rowSums(subset_table)
    col_norm_subset_table <- t(apply(subset_table,1,function(x) x/timeseries_totals))
    # If a column has been removed by filter step, normalization
    # returns NaNs and for some reason Inf
    # set it as zero to remove gaps in plot
    col_norm_subset_table[is.nan(col_norm_subset_table)] <- 0
    col_norm_subset_table[is.infinite(col_norm_subset_table)] <- 0
    double_norm <- col_norm_subset_table/rowSums(col_norm_subset_table)
    # Plotting code for main time-series plot
    layout(as.matrix(cbind(c(1,3),c(2,4))))
    matplot(tp, t(subset_table),
            type='l', main=paste("Cluster", input$cluster_number),
            xlab="Time", ylab="Sequence Abundance", col="#00000080")
    matplot(tp, t(col_norm_subset_table),
            type='l', main=paste("Cluster", input$cluster_number, "Normalized by Sequence Depth"),
            xlab="Time", ylab="Sequence Relative Abundance", col="#00000080")
    matplot(tp, t(norm_subset_table),
            type='l', main=paste("Cluster", input$cluster_number, "Normalized Within Time-series"),
            xlab="Time", ylab="Sequence Relative Abundance", col="#00000080")
    matplot(tp, t(double_norm),
            type='l', main=paste("Cluster", input$cluster_number, "Normalized by Sequence Depth and Within Time-series"),
            xlab="Time", ylab="Sequence Relative Abundance", col="#00000080")
  }, height=900, width=1200)
  
  # Plot by OTU number
  output$otu_plot <- renderPlot({
    if (is.null(input$otu_number))
      return()
    # Take only the time-series that are in the current cluster
    subset_table <- timeseries_table[sequencecluster_labels==input$otu_number, ]
    subset_table <- as.matrix(subset_table)
    # Fix behaviour when there's only one row, it makes it
    # column-wise, so we have to transpose it
    if (dim(subset_table)[2] == 1) {
      subset_table <- t(subset_table)
    }
    norm_subset_table <- subset_table/rowSums(subset_table)
    col_norm_subset_table <- t(apply(subset_table,1,function(x) x/timeseries_totals))
    # If a column has been removed by filter step, normalization
    # returns NaNs and for some reason Inf
    # set it as zero to remove gaps in plot
    col_norm_subset_table[is.nan(col_norm_subset_table)] <- 0
    col_norm_subset_table[is.infinite(col_norm_subset_table)] <- 0
    double_norm <- col_norm_subset_table/rowSums(col_norm_subset_table)
    time_clusts <- current_clusters[sequencecluster_labels==input$otu_number]
    # Plotting code for main time-series plot
    layout(as.matrix(cbind(c(1,3),c(2,4))))
    matplot(tp, t(subset_table),
            type='l', main=paste("Cluster", input$otu_number),
            xlab="Time", ylab="Sequence Abundance", col=as.factor(time_clusts))
    matplot(tp, t(col_norm_subset_table),
            type='l', main=paste("Cluster", input$otu_number, "Normalized by Sequence Depth"),
            xlab="Time", ylab="Sequence Relative Abundance", col=as.factor(time_clusts))
    matplot(tp, t(norm_subset_table),
            type='l', main=paste("Cluster", input$otu_number, "Normalized Within Time-series"),
            xlab="Time", ylab="Sequence Relative Abundance", col=as.factor(time_clusts))
    matplot(tp, t(double_norm),
            type='l', main=paste("Cluster", input$otu_number, "Normalized by Sequence Depth and Within Time-series"),
            xlab="Time", ylab="Sequence Relative Abundance", col=as.factor(time_clusts))
  }, height=900, width=1200)
  
  #Generates a table with the abundance, taxonomy, and cluster information
  output$infotable <- renderDataTable({
    if (is.null(input$cluster_param))
      return()
    if (is.null(input$cluster_number))
      return()
    subset_ids <- sequence_ids[current_clusters==input$cluster_number]
    subset_table <- timeseries_table[current_clusters==input$cluster_number, ]
    tax_ids <- taxonomic_ids[current_clusters==input$cluster_number]
    phylo_clusters <- sequencecluster_labels[current_clusters==input$cluster_number]
    data.frame(Abundance=rowSums(subset_table),
               PhyloClusterNumber=phylo_clusters,
               TaxonomicID=tax_ids,
               SequenceID=subset_ids)
  })
  
  #Generates a table with the abundance, taxonomy, and cluster information
  output$otutable <- renderDataTable({
    if (is.null(input$otu_number))
      return()
    subset_ids <- sequence_ids[sequencecluster_labels==input$otu_number]
    subset_table <- timeseries_table[sequencecluster_labels==input$otu_number, ]
    subset_table <- as.matrix(subset_table)
    if (dim(subset_table)[2] == 1) {
      subset_table <- t(subset_table)
    }
    tax_ids <- taxonomic_ids[sequencecluster_labels==input$otu_number]
    time_clusts <- current_clusters[sequencecluster_labels==input$otu_number]
    data.frame(Abundance=rowSums(subset_table),
               TimeClustNumber=time_clusts,
               TaxonomicID=tax_ids,
               SequenceID=subset_ids)
  })
  
  output$saveTable <- downloadHandler(
    filename <- function() {
      paste('timeseries_cluster-eps_', input$cluster_param, "-num_", input$cluster_number, '.csv', sep="")
    },
    content <- function(file) {
        subset_ids <- sequence_ids[current_clusters==input$cluster_number]
        subset_table <- timeseries_table[current_clusters==input$cluster_number, ]
        tax_ids <- taxonomic_ids[current_clusters==input$cluster_number]
        phylo_clusters <- sequencecluster_labels[current_clusters==input$cluster_number]
        save_df <- data.frame(SequenceID=subset_ids,
               Abundance=rowSums(subset_table),
               TaxonomicID=tax_ids,
               PhyloClusterNumber=phylo_clusters)
        time_series <- as.data.frame(timeseries_table[current_clusters==input$cluster_number, ])
        colnames(time_series) <- tp
        save_df <- cbind(save_df, time_series)
        write.csv(save_df, file)
    }
  )
  
  # Save time cluster plot as SVG
  output$saveMainPlot <- downloadHandler(
  filename <- function() {
      paste('timeseries_cluster-eps_', input$cluster_param, "-num_", input$cluster_number, '.svg', sep="")
    },
    content <- function(file) {
        #Take only the time-series that are in the current cluster
        subset_table <- timeseries_table[current_clusters==input$cluster_number, ]
        #Make a normalized version
        norm_subset_table <- subset_table/rowSums(subset_table)
        col_norm_subset_table <- t(apply(subset_table,1,function(x) x/timeseries_totals))
        # If a column has been removed by filter step, normalization
        # returns NaNs and for some reason Inf
        # set it as zero to remove gaps in plot
        col_norm_subset_table[is.nan(col_norm_subset_table)] <- 0
        col_norm_subset_table[is.infinite(col_norm_subset_table)] <- 0
        double_norm <- col_norm_subset_table/rowSums(col_norm_subset_table)
        #Plotting code for main time-series plot
        svg("tsplot.svg",height=9,width=12)
        # Plotting code for main time-series plot
        layout(as.matrix(cbind(c(1,3),c(2,4))))
        matplot(tp, t(subset_table),
              type='l', main=paste("Cluster", input$cluster_number),
              xlab="Time", ylab="Sequence Abundance", col="#00000080")
        matplot(tp, t(col_norm_subset_table),
              type='l', main=paste("Cluster", input$cluster_number, "Normalized by Sequence Depth"),
              xlab="Time", ylab="Sequence Relative Abundance", col="#00000080")
        matplot(tp, t(norm_subset_table),
              type='l', main=paste("Cluster", input$cluster_number, "Normalized Within Time-series"),
              xlab="Time", ylab="Sequence Relative Abundance", col="#00000080")
        matplot(tp, t(double_norm),
              type='l', main=paste("Cluster", input$cluster_number, "Normalized by Sequence Depth and Within Time-series"),
              xlab="Time", ylab="Sequence Relative Abundance", col="#00000080")
        dev.off()
        file.copy("tsplot.svg", file)
    }
  )
})