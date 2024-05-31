FROM r-base:4.3.3

RUN apt update -y && apt install libcurl4-openssl-dev libssl-dev curl gpg -y

RUN curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
RUN echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | tee -a /etc/apt/sources.list.d/google-cloud-sdk.list
RUN apt-get update && apt install google-cloud-sdk -y
RUN R -e "install.packages('renv', repos = c(CRAN = 'https://cloud.r-project.org'))"

WORKDIR /project

COPY .Rprofile .Rprofile

COPY renv.lock .

RUN mkdir -p renv
COPY renv/activate.R renv/activate.R
COPY renv/settings.dcf renv/settings.dcf
RUN mkdir renv/.cache
RUN R -e "renv::restore(prompt = F)"

COPY bq_utils.R .
COPY helpers.R .
COPY forecast.R .

ENTRYPOINT ["Rscript", "/project/forecast.R"]
