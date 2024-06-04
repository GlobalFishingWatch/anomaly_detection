import logging
import argparse
from google.cloud import bigquery
import os
from slack_sdk.webhook import WebhookClient

SLACK_WEBHOOK_URL=os.getenv('SLACK_WEBHOOK_URL')

webhook=WebhookClient(SLACK_WEBHOOK_URL)

client=bigquery.Client()

def get_query_results(
    environment, 
    interval_from='TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 48 HOUR)', 
    interval_to='TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 0 HOUR)'
):
    query=f"""
    SELECT * FROM `world-fishing-827.tech_anomaly_detection.v_{environment}_deltas`
    WHERE anomaly_type != 'normal'
    AND delta_valid_from BETWEEN {interval_from} AND {interval_to} -- get anomalies from previous hour
    """

    query_job=client.query(query)
    results=query_job.result()

    return results

def create_anomaly_alert_slack_message(
    anomaly_config_name, 
    description, 
    anomaly_type, 
    anomaly_timestamp, 
    forecast_value, 
    forecast_method,
    actual_value, 
    threshold,
    delta_rel,
    query, 
    looker_dashboard_url
):
    alert_emoji=":red_circle:" if anomaly_type == 'critical' else ":large_yellow_circle:"
    description=description if description else "No description available"
    url=looker_dashboard_url.format(ANOMALY_CONFIG_NAME=anomaly_config_name, FC_METHOD=forecast_method)
    msg_text=f"""
    {alert_emoji} 
    *Anomaly*: {anomaly_config_name}. 
    *URL*: {url}
    *Anomaly level*: {anomaly_type}
    *Timestamp*: {anomaly_timestamp}
    *Forecast value*: {forecast_value}
    *Actual value*: {actual_value}
    *Relative delta*: {delta_rel}
    *Threshold*: {threshold}
    *Description*: {description}
    *Query*: 
    ```
    {query}
    ```
    """
    message={
        'text': msg_text,
        'type': 'mrkdwn'
    }
    return message


def run(environment, interval_from, interval_to, looker_dashboard_url):
    results=get_query_results(environment, interval_from, interval_to)

    for row in results:
        logging.info(row)
        rendered_message=create_anomaly_alert_slack_message(
            anomaly_config_name=row['config_name'],
            description=row['description'],
            anomaly_type=row['anomaly_type'],
            anomaly_timestamp=row['timestamp'],
            forecast_value=row['forecast_value'],
            forecast_method=row['forecast_method'],
            actual_value=row['actual_value'],
            threshold=row['exceeded_threshold_lower_higher'],
            delta_rel=row['delta_rel'],
            query=row['source_sql'],
            looker_dashboard_url=looker_dashboard_url
        )

        if SLACK_WEBHOOK_URL is not None:
            response=webhook.send(
                text=rendered_message['text']
            )
            logging.info(response.status_code)
            logging.info(response.body)
        else:
            logging.info("No SLACK_WEBHOOK_URL provided. Skipping sending message to slack.")
        

if __name__ == '__main__':
  logging.getLogger().setLevel(logging.INFO)
  
  parser=argparse.ArgumentParser()
  parser.add_argument(
      '--environment',
      help='Environment: dev, staging, prod',
      dest='environment',
      required=True
  )
  parser.add_argument(
      '--interval-from',
      help='Interval from',
      dest='interval_from',
      default='TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 48 HOUR)',
      required=False
  )
  parser.add_argument(
      '--interfal-to',
        help='Interval to',
        dest='interval_to',
        default='TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 0 HOUR)',
        required=False
  )
  parser.add_argument(
        '--looker-dashboard-url',
        help='Looker dashboard URL',
        dest='looker_dashboard_url',
        default='https://lookerstudio.google.com/u/0/reporting/1f9b8d37-a87b-4177-a108-3b3e87ce5804/page/p_ufk1l0slhd?s=sMwwKK9Ni_4&params=%7B%22df34%22:%22include%25EE%2580%25800%25EE%2580%2580IN%25EE%2580%2580{ANOMALY_CONFIG_NAME}%22,%22df18%22:%22include%25EE%2580%25800%25EE%2580%2580IN%25EE%2580%2580{FC_METHOD}%22%7D'
        required=False
    )
  
  known_args, _=parser.parse_known_args()
  
  run(
        known_args.environment, 
        known_args.interval_from,
        known_args.interval_to,
        known_args.looker_dashboard_url
     ) 
     