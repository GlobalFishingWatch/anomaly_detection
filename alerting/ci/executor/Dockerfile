FROM python:3.10

RUN apt update -y && apt-get upgrade -y && apt install libcurl4-openssl-dev libssl-dev curl gpg -y

# install gcloud so we can google.cloud import bigquery
RUN curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
RUN echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | tee -a /etc/apt/sources.list.d/google-cloud-sdk.list
RUN apt-get update && apt install google-cloud-sdk -y

WORKDIR /code

COPY requirements.txt .
RUN pip install -r requirements.txt

COPY main.py main.py

ENTRYPOINT ["python3", "-u", "main.py"]