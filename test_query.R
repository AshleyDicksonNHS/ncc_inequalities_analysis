# Test script to run the NCC base dataset query
# Run this in RStudio or R console

library(tidyverse)
library(DBI)
library(odbc)

# Database connection
driver <- "ODBC Driver 17 for SQL Server"
server <- "udalsyndataprod.sql.azuresynapse.net"
database <- "UDAL_Warehouse"
uid <- Sys.getenv("UDAL_USER", unset = "your.name@udal.nhs.uk")

con <- DBI::dbConnect(odbc(),
                      Driver = driver,
                      Server = server,
                      Database = database,
                      UID = uid,
                      Authentication = "ActiveDirectoryInteractive",
                      Port = 1433)

# Read and execute query
query_file <- "NCC_base_dataset_query.sql"
query <- readLines(query_file) %>% paste(collapse = "\n")

cat("Executing query...\n")
cat("This may take several minutes...\n\n")

result <- tryCatch({
  dbGetQuery(con, query)
}, error = function(e) {
  cat("ERROR:\n")
  cat(conditionMessage(e), "\n\n")
  return(NULL)
})

if (!is.null(result)) {
  cat("Success!\n")
  cat("Rows returned:", nrow(result), "\n")
  cat("Columns:", ncol(result), "\n")
  cat("\nColumn names:\n")
  print(names(result))

  cat("\nFirst few rows:\n")
  print(head(result))
}

dbDisconnect(con)
