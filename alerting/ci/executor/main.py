import logging
import argparse
from google.cloud import bigquery
import os
from slack_sdk.webhook import WebhookClient

SLACK_WEBHOOK_URL = os.getenv('SLACK_WEBHOOK_URL')

webhook = WebhookClient(SLACK_WEBHOOK_URL)

client = bigquery.Client()

def get_query_results(environment, config_name, anomaly_type):
    query = f"""
    SELECT * FROM `world-fishing-827.tech_anomaly_detection.v_{environment}_deltas`
    WHERE anomaly_type != 'normal'
    AND timestamp BETWEEN TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 2 HOUR) AND TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 HOUR) -- get anomalies from previous hour
    """

    query_job = client.query(query)
    results = query_job.result()

    return results

def create_anomaly_alert_slack_message(anomaly_config_name, description, anomaly_type, anomaly_timestamp, forecast_value, actual_value, query):
    alert_emoji = ":red_circle:" if anomaly_type == 'critical' else ":large_yellow_circle:"
    msg_text = f"""
    :{alert_emoji}: Anomaly {anomaly_config_name}. 
    *Anomaly level*: {anomaly_type}
    *Timestamp*: {anomaly_timestamp}
    *Forecast value*: {forecast_value}
    *Actual value*: {actual_value}
    {*Description*: {description} if description else "No description available"}
    *Query*: 
    ```
    {query}
    ```
    """
    message = {
        'text': msg_text,
        'mrkdwn': True
    }
    return message


def run(environment, config_name, anomaly_type):
    results = get_query_results(environment, config_name, anomaly_type)

    for row in results:
        logging.info(row)
        rendered_message = create_anomaly_alert_slack_message(
            row['config_name'],
            row['description'],
            row['anomaly_type'],
            row['timestamp'],
            row['forecast_value'],
            row['actual_value'],
            row['source_sql']
        )

        response = webhook.send(
            text=rendered_message['text']
        )

        logging.info(response.status_code)
        logging.info(response.body)
        

if __name__ == '__main__':
  logging.getLogger().setLevel(logging.INFO)
  
  parser = argparse.ArgumentParser()
  parser.add_argument(
      '--environment',
      help='Environment: dev, staging, prod',
      dest='environment',
      required=True
  )
  
  known_args, _ = parser.parse_known_args()
  
  run(
     known_args.environment, 
     known_args.config_name, 
     known_args.anomaly_type
     ) 
     