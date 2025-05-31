parse_wk = function(df_with_wk) {
  df_with_wk %>% 
    mutate(across(where(~ is_wk_wkb(.x) || is_wk_wkt(.x)), ~ paste0(
      as_xy(.x) %>% xy_x(),
      ",",
      as_xy(.x) %>% xy_y()
    )))
}


#' @export
BQ_KB = 1024

#' @export
BQ_MB = BQ_KB * 1024

#' @export
BQ_GB = BQ_MB * 1024

#' @export
allowed_size = 0.1 * BQ_GB



#' Estimate BQ query size
#'
#' @param query 
#'
#' @return
#' @export
#'
#' @examples
estimate_query_size = function(query, billing = Sys.getenv("GCP_PROJECT_ID", "world-fishing-827")) {
  if("tbl_lazy" %in% class(query)) {
    query %<>% sql_render()
  }
  bigrquery::bq_perform_query_dry_run(query, billing = billing)
}

#' Validate big query size
#' 
#' Convenience wrapper around [estimate_query_size] for running safe queries that do not exceed
#' a given upper bound.
#' 
#' Warnings are raised if the allowed_query size is exceeded or if the allowed_query size exceeds
#' the estimated query size by more than 50%, in which case a lower allowed_size value should be 
#' provided
#'
#' @param query The SQL query string for which the estimated size is to be compared to a given limit 
#' @param allowed_size Integer indicating the upper limit in bytes which is allowed for the 
#' validation to succeed
#'
#' @return boolean indicating whether the estimated query size exceeds the given allowed_size
#' @export
#'
#' @examples
validate_query_size = function(query, allowed_size = 0.1 * BQ_GB) {
  if("tbl_lazy" %in% class(query)) {
    if(con %>% is.null()) con = query[1]$src$con
    query %<>% sql_render()
  }
  query_estimate = estimate_query_size(query)
  if(query_estimate > allowed_size) {
    warning(glue("Query exceeds allowed_size
                 allowed_size = {utils:::format.object_size(allowed_size, units = 'GB')}
                 estimated size = {utils:::format.object_size(query_estimate, units = 'GB')}
                 
                 ")) 
  } else if (query_estimate * 1.5 < allowed_size) {
    warning(glue("Query allowed_size is set more than 50% higher than estimated_size
                  You can and probably should set the allowed_size closer to the estimated_size
                 allowed_size = {utils:::format.object_size(allowed_size, units = 'GB')}
                 estimated size = {utils:::format.object_size(query_estimate, units = 'GB')}
                 
                 ")) 
  }
  return(query_estimate <= allowed_size)
}

#' Run safe BQ query
#'
#' @param query 
#' @param con 
#' @param allowed_size 
#'
#' @return
#' @import data.table
#' @export
#'
#' @examples
safe_query = function(query, con, allowed_size = 0.1 * BQ_GB, 
                      query_size_exceeded_handling = c("stop", "skip")[1], page_size = NULL,
                      verbose = F) {
  if("tbl_lazy" %in% class(query)) {
    if(con %>% is.null()) con = query[1]$src$con
    query %<>% sql_render()
  }
  if (verbose) cat(query, fill = T)
  if (validate_query_size(query = query, allowed_size = allowed_size)) {
    if (page_size %>% is.null()) {
      DBI::dbGetQuery(con, query) %>% setDT()
    } else {
      DBI::dbGetQuery(con, query, n = page_size) %>% setDT()
    }
  } else {
    if (query_size_exceeded_handling == "stop") {
      stop("Query size limit exceeded!") 
    } else if (query_size_exceeded_handling == "skip") {
      warning("Query size limit exceeded!")
    }
  }
}