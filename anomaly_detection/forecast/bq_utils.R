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
estimate_query_size = function(query, billing = "world-fishing-827") {
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
  if (verbose) cat(query, fill = T)
  if("tbl_lazy" %in% class(query)) {
    if(con %>% is.null()) con = query[1]$src$con
    query %<>% sql_render()
  }
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

# 1) hash query (md5)
# 2) lookup whether bq results have been stored in cache and retrieve as DT (using hash as filename)
# 3) run safe query if not found in cache
# 4) store result in cache as well as beautified query using hash key as filename
#' Run safe cached BQ query
#'
#' @param query 
#' @param con 
#' @param allowed_size 
#' @param cache_dir 
#' @param cache_version 
#'
#' @return
#' @export
#' @import data.table arrow
#' @importFrom prettyfile beautify_str
#'
#' @examples
safe_cached_query = function(query, con = NULL, allowed_size = NULL, 
                             cache_dir = ".cached_queries", cache_version = NULL, 
                             overwrite_if_cached = F, verbose = F, 
                             query_size_exceeded_handling = c("stop", "warning", "skip")[1],
                             page_size = NULL) {
  if("tbl_lazy" %in% class(query)) {
    if(con %>% is.null()) con = query[1]$src$con
    query %<>% sql_render()
  }
  beautified_query = query %>% 
    prettyfile::beautify_str("sql")
  query_hash = digest::digest(beautified_query, algo = "md5")
  # for compatibility with minified queries also check whether minified query has been cached
  query_hash_minified = query %>% 
    prettyfile::minify_str("sql") %>% 
    prettyfile::beautify_str("sql") %>% 
    digest::digest(algo = "md5")
  if(!is.null(cache_version)) {
    query_dir = file.path(cache_dir, cache_version)
  } else if(exists("cache_version", .GlobalEnv)) {
    query_dir = file.path(cache_dir, get("cache_version", .GlobalEnv))
  } else {
    warning("Warning: No cache version provided, using global cache!")
    query_dir = file.path(cache_dir)
  }
  if(is.null(allowed_size)) {
    if(exists("allowed_size", .GlobalEnv)) {
      allowed_size = get("allowed_size", .GlobalEnv) 
    } else {
      warning("Didn't find allowed_size in parameter or .GlobalEnv, setting it to 0.1 * BQ_GB")
      allowed_size = 0.1 * BQ_GB
    }
  }
  query_path = file.path(query_dir, query_hash)
  query_path_minified = file.path(query_dir, query_hash_minified)
  query_sql_path = file.path(query_dir, paste0(query_hash, ".sql"))
  if (!overwrite_if_cached & exists("overwrite_if_cached_next", envir = .GlobalEnv)) {
    if (get("overwrite_if_cached_next", .GlobalEnv) == "TRUE") {
      overwrite_if_cached = T
      assign("overwrite_if_cached_next", value = F, envir = .GlobalEnv)
    }
  }
  if (overwrite_if_cached | exists("overwrite_if_cached_permanent", envir = .GlobalEnv)) {
    if (file.exists(query_path)) {
      file.remove(query_path)
    } else {
      warning("overwrite_if_cached has been set to true but cached file didn't exist anyway!")
    }
  }
  if (file.exists(query_path)) {
    cat("Query found in cache - retrieving result", fill = T)
    return(arrow::read_feather(query_path) %>% setDT())
  } else {
    dt = safe_query(query = query, con = con, allowed_size = allowed_size, page_size = page_size, 
                    verbose = verbose)
    if (!dir.exists(dirname(query_path))) dir.create(dirname(query_path), recursive = T)
    
    if ("list" %in% dt[, lapply(.SD, class)]) {
      list_cols = names(intersect("list", dt[, lapply(.SD, class)]))
      # warning("query returns list type column which cannot be cached\n")
      # warning(glue("removing the following list columns before caching: {paste0(list_cols, collapse = ' , ')}\n"))
      # dt[, (list_cols) := NULL]
    }
    if ("wk_wkt" %in% dt[, lapply(.SD, class)]) {
      wk_wkt_cols = names(intersect("wk_wkt", dt[, lapply(.SD, class)]))
      warning("query returns list type column which cannot be cached\n")
      warning(glue("removing the following list columns before caching: {paste0(list_cols, collapse = ' , ')}\n"))
      dt[, (wk_wkt) := lapply(.SD, parse_wk), .SDcols = wk_wkt_cols]
    }
    dt %>% 
      arrow::write_feather(query_path)
    beautified_query %>% 
      writeLines(query_sql_path)
    return(dt)
  }
}