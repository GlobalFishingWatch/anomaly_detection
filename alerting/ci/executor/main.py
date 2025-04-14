import logging
import argparse
from google.cloud import bigquery
import os
from slack_sdk.webhook import WebhookClient
import datetime
import json
import hashlib
import urllib.parse

SLACK_WEBHOOK_URL=os.getenv('SLACK_WEBHOOK_URL')

webhook=WebhookClient(SLACK_WEBHOOK_URL)

client=bigquery.Client()

def make_looker_studio_url(report_id, page_id, config_name, fc, dimension):
    params_json={'PARAM_CONFIG_NAME': config_name, 'PARAM_FC': fc, 'PARAM_DIMENSION': dimension}
    encoded_params=urllib.parse.quote(json.dumps(params_json))
    url_with_params=f"https://lookerstudio.google.com/reporting/{report_id}/page/{page_id}?params={encoded_params}"
    logging.info(f"Looker Studio URL: {url_with_params}")
    return url_with_params

def write_event_to_bigquery(event_hash, rendered_message, environment, deduplication_window=30*24*60*60):
    query = f"""
    SELECT * FROM `world-fishing-827.tech_anomaly_detection.qa-gfw-anomaly-detection-alerting-{environment}_deduplication-index`
    WHERE event_hash = '{event_hash}'
    """
    query_job = client.query(query)
    results = query_job.result()

    results = list(results)
    processing_timestamp = datetime.datetime.now(datetime.timezone.utc)
    if results:
        print(f"Event already processed at {results[0].get('processed_at')}.")
        if (processing_timestamp - results[0].get('processed_at')).total_seconds() < deduplication_window:
            print(f"Event is within deduplication window. Skipping.")
            return False
        else:
            print(f"Event is outside deduplication window. Processing.")
    
    query = f"""
    INSERT INTO `world-fishing-827.tech_anomaly_detection.qa-gfw-anomaly-detection-alerting-{environment}_deduplication-index`
    VALUES (@event_hash, @processing_timestamp, @rendered_message)
    """
    job_config = bigquery.QueryJobConfig(
        query_parameters=[
            bigquery.ScalarQueryParameter("event_hash", "STRING", event_hash),
            bigquery.ScalarQueryParameter("processing_timestamp", "TIMESTAMP", processing_timestamp),
            bigquery.ScalarQueryParameter("rendered_message", "STRING", rendered_message)
        ]
    )
    query_job = client.query(query, job_config=job_config)
    results = query_job.result()
    print(f"Event written to BigQuery.")
    return True

def get_query_results(
    environment, 
    query_template
):
    query=query_template.format(environment=environment)

    query_job=client.query(query, job_config=bigquery.QueryJobConfig(use_query_cache=False))
    results=query_job.result()

    return results

def create_anomaly_alert_slack_message(
    anomaly_config_name, 
    dimension_split_value,
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
    dimension=f'\n*Dimension*: {dimension_split_value}' if dimension_split_value != '' else ""
    message=f"""{alert_emoji}
*Anomaly*: {anomaly_config_name}{dimension}
*URL*: <{looker_dashboard_url}|Anomaly Detection Dashboard>
*Anomaly level*: {anomaly_type}
*Timestamp*: {anomaly_timestamp}
*Forecast value*: {forecast_value}
*Forecast method*: {forecast_method}
*Actual value*: {actual_value}
*Relative delta*: {delta_rel}
*Threshold*: {threshold}
*Description*: {description}
*Query*: 
```
SELECT{query}
```"""
    return message


def run(environment, query_template, report_id, page_id, deduplication_window):
    results=get_query_results(environment, query_template)

    for row in results:
        logging.info(row)
        looker_dashboard_url=make_looker_studio_url(report_id, page_id, row['config_name'], row['forecast_method'], row['dimension_split_value'])
        rendered_message=create_anomaly_alert_slack_message(
            anomaly_config_name=row['config_name'],
            dimension_split_value=row['dimension_split_value'],
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

        logging.info(rendered_message)

        # Calculate the hash based on the columns used in rendered_message
        columns_used = [
            row['config_name'],
            row['dimension_split_value'],
            row['description'],
            row['anomaly_type'],
            row['timestamp'],
            row['forecast_value'],
            row['forecast_method'],
            row['actual_value'],
            row['exceeded_threshold_lower_higher'],
            row['delta_rel'],
            row['source_sql']
        ]
        
        event_hash = hashlib.sha256(str(columns_used).encode()).hexdigest()

        logging.info(event_hash)

        if SLACK_WEBHOOK_URL is not None:
            if write_event_to_bigquery(event_hash=event_hash, rendered_message=rendered_message, environment=environment, deduplication_window=deduplication_window):
                response=webhook.send(text=rendered_message)
                assert response.status_code == 200
                assert response.body == "ok"
                logging.info(response.status_code)
                logging.info(response.body)
            else:
                logging.info("Event already processed. Skipping sending message to slack.")
        else:
            logging.warning("No SLACK_WEBHOOK_URL provided. Skipping sending message to slack.")
        

if __name__ == '__main__':
  log_level = os.getenv('LOG_LEVEL', 'INFO').upper()
  logging.basicConfig(level=log_level)
  
  parser=argparse.ArgumentParser()
  parser.add_argument(
      '--environment',
      help='Environment: dev, staging, prod',
      dest='environment',
      required=True
  )
  parser.add_argument(
    '--query-template',
    help='SQL anomaly query template',
    dest='query_template',
    required=False,
    default='''
    SELECT * FROM `world-fishing-827.tech_anomaly_detection.t_{environment}_deltas`
    WHERE anomaly_type != 'normal'
    AND timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30*24 HOUR)
    ORDER BY timestamp DESC
    '''
  )
  parser.add_argument(
        '--looker-report-id',
        help='Looker report id',
        dest='report_id',
        default='1f9b8d37-a87b-4177-a108-3b3e87ce5804',
        required=False
    )
  parser.add_argument(
        '--looker-page-id',
        help='Looker page id',
        dest='page_id',
        default='p_ufk1l0slhd',
        required=False
    )
  parser.add_argument(
        '--deduplication-window',
        help='Deduplication window in seconds',
        dest='deduplication_window',
        default=30*24*60*60,
        required=False
    )
  
  known_args, _=parser.parse_known_args()
  
  run(
        known_args.environment, 
        known_args.query_template,
        known_args.report_id,
        known_args.page_id,
        known_args.deduplication_window
     ) 
     