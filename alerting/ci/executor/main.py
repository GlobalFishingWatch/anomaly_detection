import logging
import argparse
from google.cloud import bigquery

client = bigquery.Client()


def get_query_results(environment, config_name, anomaly_type):
    query = f"""
    SELECT * FROM `world-fishing-827.tech_great_expectations.v_${environment}_anomaly_detection_deltas`
    WHERE config_name = '${config_name}'
    AND anomaly_type = "${anomaly_type}"
    """

    query_job = client.query(query)
    results = query_job.result()

    return results

def run(environment, config_name, anomaly_type):
    results = get_query_results(environment, config_name, anomaly_type)

    for row in results:
        logging.info(row)

if __name__ == '__main__':
  logging.getLogger().setLevel(logging.INFO)
  
  parser = argparse.ArgumentParser()
  parser.add_argument(
      '--environment',
      help='Environment: dev, staging, prod',
      dest='environment',
      required=True
  )
  parser.add_argument(
      '--config-name',
      help='Config name',
      dest='config_name',
      required=True
  )
  parser.add_argument(
      '--anomaly-type',
      help='Anomaly type',
      dest='anomaly_type',
      required=True
  )
  
  known_args, _ = parser.parse_known_args()
  
  run(
     known_args.environment, 
     known_args.config_name, 
     known_args.anomaly_type
     ) 
     