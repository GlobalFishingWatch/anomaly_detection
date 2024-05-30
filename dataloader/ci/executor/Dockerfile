FROM r-base:4.1.2

RUN apt update -y && apt install libcurl4-openssl-dev libssl-dev curl gpg -y

RUN curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
RUN echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | tee -a /etc/apt/sources.list.d/google-cloud-sdk.list
RUN apt-get update && apt install google-cloud-sdk -y
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
COPY .renv/ renv

COPY sa_api_key.json .

COPY bq_utils.R .
COPY helpers.R .
COPY forecast.R .

COPY init.sh .
RUN chmod +x init.sh

COPY actuals_schema.json .
COPY forecasts_schema.json .

ENTRYPOINT ["/project/init.sh"]
CMD [ "bash" ]
