import logging
import argparse
from google.cloud import bigquery
import os
import datetime
import json
import hashlib
import urllib.parse
from slack_sdk import WebClient
from slack_sdk.errors import SlackApiError

SLACK_BOT_TOKEN=os.getenv('SLACK_BOT_TOKEN')

client=bigquery.Client()
slack_client=WebClient(token= SLACK_BOT_TOKEN)

def make_looker_studio_url(report_id, page_id, config_name, fc, dimension):
    params_json={'PARAM_CONFIG_NAME': config_name, 'PARAM_FC': fc, 'PARAM_DIMENSION': dimension}
    encoded_params=urllib.parse.quote(json.dumps(params_json))
    url_with_params=f"https://lookerstudio.google.com/reporting/{report_id}/page/{page_id}?params={encoded_params}"
    logging.info(f"Looker Studio URL: {url_with_params}")
    return url_with_params

def write_event_to_bigquery(event_hash, rendered_message, deduplication_index, deduplication_window=30*24*60*60):
    query = f"""
    SELECT * FROM `{deduplication_index}`
    WHERE event_hash = '{event_hash}'
    """
    query_job = client.query(query)
    results = query_job.result()

    results = list(results)
    processing_timestamp = datetime.datetime.now(datetime.timezone.utc)
    if results:
        logging.info(f"Event already processed at {results[0].get('processed_at')}.")
        if (processing_timestamp - results[0].get('processed_at')).total_seconds() < deduplication_window:
            logging.info("Event is within deduplication window. Skipping.")
            return False
        else:
            logging.info("Event is outside deduplication window. Processing.")
    
    query = f"""
    INSERT INTO `{deduplication_index}`
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
    logging.info("Event written to BigQuery.")
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
    environment,
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
    anomaly_alerting_environment=f'\n*Environment*: {environment}' if environment != 'prod' else ""
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
{anomaly_alerting_environment}
*Query*: 
```
SELECT{query}
```"""
    return message


def get_slack_channel_id(config_name, environment):
    slack_channel_query = f"""
    SELECT
        CASE
            WHEN config_name = '{config_name}' AND environment = '{environment}' THEN 1
            WHEN config_name IS NULL AND environment = '{environment}' THEN 2
            ELSE 3
        END AS prioritisation,
        config_name,
        environment,
        slack_channel_id,
        slack_channel_name
    FROM `world-fishing-827.tech_anomaly_detection.slack_channels_environments_config_mapping`
    ORDER BY prioritisation
    LIMIT 1
    """

    query_job = client.query(slack_channel_query)
    results = query_job.result()

    # throw error if no priortisation 1 or 2
    # or if results empty
    if not results:
        raise ValueError("No results found for the given config_name and environment.")
    
    for row in results:
        slack_channel_id = row['slack_channel_id']
        slack_channel_name = row['slack_channel_name']
        if row['prioritisation'] == 1 or row['prioritisation'] == 2:
            break
    
    if not slack_channel_id:
        raise ValueError("No slack channel id found for the given config_name and environment.")

    logging.info(f"Slack channel id: {slack_channel_id}")
    logging.info(f"Slack channel name: {slack_channel_name}")
    return slack_channel_id

def run(environment, query_template, report_id, page_id, deduplication_index, deduplication_window):
    results=get_query_results(environment, query_template)

    for row in results:
        logging.info(row)
        looker_dashboard_url=make_looker_studio_url(report_id, page_id, row['config_name'], row['forecast_method'], row['dimension_split_value'])
        rendered_message=create_anomaly_alert_slack_message(
            environment=environment,
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

        # We write the event hash to the bigquery deduplication index if it is not already present
        # if it is present, we skip sending the slack alert
        # TODO: this is a bit problematic in case the slack alert fails because we have already inserted the event hash
        if write_event_to_bigquery(event_hash=event_hash, rendered_message=rendered_message, deduplication_index=deduplication_index, deduplication_window=deduplication_window):
            channel_id=get_slack_channel_id(row['config_name'], environment)
            try:
                result = slack_client.chat_postMessage(channel=channel_id, text=rendered_message, unfurl_links=False)
                logging.info(result)

            except SlackApiError as e:
                logging.error(f"Error: {e}")
        else:
            logging.info("Event already processed. Skipping sending message to slack.")

if __name__ == '__main__':
  log_level = os.getenv('LOG_LEVEL', 'INFO').upper()
  logging.basicConfig(level=log_level)
  
  parser=argparse.ArgumentParser()
  parser.add_argument(
      '--environment',
      help='Environment: dev, staging, prod',
      dest='environment',
      required=False,
      default='dev'
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
    ORDER BY timestamp DESC, config_name, dimension_split_value
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
        '--deduplication-index',
        help='BigQuery table for deduplication',
        dest='deduplication_index',
        required=False,
        default=''
    )
  parser.add_argument(
        '--deduplication-window',
        help='Deduplication window in seconds',
        dest='deduplication_window',
        default=30*24*60*60,
        required=False
    )
  
  known_args, _=parser.parse_known_args()
  
  
  environment = known_args.environment
  query_template = known_args.query_template
  report_id = known_args.report_id
  page_id = known_args.page_id
  deduplication_window = known_args.deduplication_window
  
  if known_args.deduplication_index == '':
      deduplication_index = f"world-fishing-827.tech_anomaly_detection.t_qa_gfw_anomaly_detection_alerting_{environment}_deduplication-index"
  else:
      deduplication_index = known_args.deduplication_index
  
  run(
      environment=environment,
      query_template=query_template,
      report_id=report_id,
      page_id=page_id,
      deduplication_index=deduplication_index,
      deduplication_window=deduplication_window
      ) 
      