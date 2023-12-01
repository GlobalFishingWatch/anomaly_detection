FROM r-base:4.1.2

RUN apt update -y
RUN apt install libcurl4-openssl-dev libssl-dev -y

RUN R -e "install.packages('renv', repos = c(CRAN = 'https://cloud.r-project.org'))"

WORKDIR /project

COPY .Rprofile .Rprofile
COPY renv.lock .

## This should later be used in production but takes much longer than using the installed libraries from local host
# RUN mkdir -p renv
# COPY renv/activate.R renv/activate.R
# COPY renv/settings.dcf renv/settings.dcf
# RUN mkdir renv/.cache
# RUN --mount=type=cache,target=renv/.cache R -e "renv::restore(prompt = F)"

## Copy libraries from local host
COPY ./renv/ renv

COPY sa_api_key.json .

COPY bq_utils.R .
COPY forecasts_schema.json .
COPY actuals_schema.json .
COPY helpers.R .
COPY forecast.R .
COPY config.yaml .

## TODO: Need to figure out where to create the tables
# RUN bq mk -t tech_great_expectations.anomaly_detection_actuals actuals_schema.json
# RUN bq mk -t tech_great_expectations.anomaly_detection_forecasts forecasts_schema.json

CMD ["Rscript", "forecast.R"]
