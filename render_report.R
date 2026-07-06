# Render the NCC Base Dataset Report
library(rmarkdown)

cat("Rendering NCC Base Dataset Report...\n")
cat("This may take a few minutes...\n\n")

rmarkdown::render(
  "NCC_Base_Dataset_Report.Rmd",
  output_file = "NCC_Base_Dataset_Report.html",
  quiet = FALSE
)

cat("\n")
cat("=========================================================\n")
cat("Report generated successfully!\n")
cat("Output: NCC_Base_Dataset_Report.html\n")
cat("=========================================================\n")
