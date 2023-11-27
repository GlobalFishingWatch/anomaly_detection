from airflow import DAG
from airflow.utils.task_group import TaskGroup
from airflow.decorators import task

import great_expectations as gx
from great_expectations_provider.operators.great_expectations import GreatExpectationsOperator

from great_expectations_experimental.expectations.expect_queried_column_values_to_exist_in_second_table_column  import ExpectQueriedColumnValuesToExistInSecondTableColumn
from great_expectations_experimental.expectations.expect_queried_custom_query_to_return_num_rows import ExpectQueriedCustomQueryToReturnNumRows


import logging
from datetime import datetime
import os

import json
from jinja2 import Template

from google.cloud import bigquery
from google.oauth2 import service_account

import aiofiles
import asyncio
from gcloud.aio.storage import Storage
import glob

import pandas as pd

from time import sleep
from random import randint

logger = logging.getLogger(__name__)

pd.set_option('display.max_rows', None)
pd.set_option('display.max_columns', None)

credentials = service_account.Credentials.from_service_account_file(
    "/mnt/encrypted_data/git/api_keys/world-fishing-827-02584bdf5326.json",
    scopes=["https://www.googleapis.com/auth/cloud-platform"],
)
client = bigquery.Client(credentials=credentials, project=credentials.project_id)

def safe_gb(bytes):
    if bytes is None:
        return 0
    else:
        return round(bytes / (1000**3), 2)

async def upload_local_directory_to_gcs(upload_list, target_bucket):
    async with Storage() as client:
        # Prepare all our upload data
        uploads = []
        for local_name, gcs_name in upload_list.items():
            async with aiofiles.open(local_name, mode="rb") as f:
                contents = await f.read()
                uploads.append((gcs_name, contents))

        # Simultaneously upload all files
        await asyncio.gather(
            *[
                client.upload(target_bucket, path, file_)
                for path, file_ in uploads
            ]
        )

@task(task_id="upload_data_docs", trigger_rule="all_done")
def upload_data_docs():
    upload_list = {}
    local_path = "/mnt/encrypted_data/git/data-testing/great_expectations/uncommitted/data_docs/local_site"
    target_bucket = "data-testing-static-website"
    remote_path = "great_expectations"
    for f in glob.glob(f"{local_path}/**/*", recursive=True):
        if os.path.isfile(f):
            remote = f.replace(local_path, remote_path)
            upload_list.update({f: remote})
    
    asyncio.run(upload_local_directory_to_gcs(upload_list=upload_list, target_bucket=target_bucket))


@task(task_id="estimate_billing", trigger_rule="all_done")
def get_jobs_statistics(**kwargs):
    min_creation_time=kwargs["dag_run"].queued_at
    jobs_list=list()
    logger.info(f"Getting jobs ({min_creation_time=}) datetimenow: {datetime.now()}")
    for job in client.list_jobs(min_creation_time=min_creation_time):
        jobs_list.append({
            'job_id': job.job_id,
            'total_bytes_billed': job.total_bytes_billed,
            'total_bytes_processed': job.total_bytes_processed,
            'estimated_bytes_processed': job.estimated_bytes_processed,
            'created': job.created,
            'started': job.started,
            'ended': job.ended,
            'query': job.query,
            'state': job.state 
        })

    if len(jobs_list) == 0:
        logger.info(f"Couldn't find any jobs since {min_creation_time}!")
        return()
        
    df_jobs=pd.DataFrame(jobs_list) \
        .assign(total_gb_billed=lambda x: safe_gb(x["total_bytes_billed"])) \
        .sort_values("total_bytes_billed", ascending=True, na_position="first")

    logger.info(df_jobs.to_json(orient='index', indent=2))
    logger.info(
        f"""

===================================

BQ Statistics for current test run:
number of jobs: {df_jobs.shape[0]}
total_bytes_billed (GB): {safe_gb(df_jobs['total_bytes_billed'].sum())}
total_bytes_processed (GB): {safe_gb(df_jobs['total_bytes_processed'].sum())}
estimated_bytes_processed (GB): {safe_gb(df_jobs['estimated_bytes_processed'].sum())}
    """)



with DAG(
    "gx_run_anomalies_checkpoints", 
    start_date=datetime(2023, 11 , 19), 
    schedule='@daily', catchup=True,
    render_template_as_native_obj=True,
    max_active_runs=1
) as dag:
    
    billing_estimate = get_jobs_statistics()

    gx_context_root_dir=os.getenv('GX_CONTEXT_ROOT_DIR')
    gx_context = gx.get_context(context_root_dir=gx_context_root_dir)
    gx_datasource = gx_context.get_datasource("gfw-google-827")

    upload_data_docs_task = upload_data_docs()

    # TODO CHO20230707 This is only robust as long as we have a 1:1 mapping of expectation suite to checkpoint
    for current_expectation_suite_name in [es for es in gx_context.list_expectation_suite_names() if 'anomalies' in es]:
        current_expectation_suite = gx_context.get_expectation_suite(current_expectation_suite_name)
        # TODO: excluder certain expectation suites more elegantly
        if current_expectation_suite.expectations \
            and "segs_activity." not in current_expectation_suite_name:
            logger.info(current_expectation_suite_name)
            current_expectation_suite_asset_name=current_expectation_suite.meta.get('asset_name')
            gx_asset=gx_datasource.get_asset(current_expectation_suite_asset_name)
            gx_splitter=gx_asset.splitter

            @task(retries=5, retry_delay=3)
            def load_templated_json(checkpoint_kwargs_dict: dict, **context):
                json_template=json.dumps(checkpoint_kwargs_dict)
                logger.info(json_template)
                jinja_template = Template(json_template)
                rendered_json_str = jinja_template.render(**context)

                # sleep for a random amount of time so we don't run into write conflicts due to GX bug:
                # https://github.com/great-expectations/great_expectations/issues/8294
                sleep(randint(0, 10))

                return json.loads(rendered_json_str)

            task_group_id=current_expectation_suite_name.replace('.', '_')
            with TaskGroup(group_id=task_group_id) as tg:
                if gx_splitter is not None:
                    DATE_PARTITION_COLUMN=gx_splitter.column_name
                    # shift current date by dummy value because pipe3 is outdated
                    br_options={DATE_PARTITION_COLUMN: "{{ macros.ds_add(ds, -3) }}"}
                else:
                    br_options={}
                gx_br = {
                    'batch_slice': None,
                    'data_asset_name': gx_asset.name,
                    'datasource_name': gx_datasource.name,
                    'options': br_options
                }

                gx_validations = {'validations': [{"batch_request": gx_br}]}

                gx_anomalies = GreatExpectationsOperator(
                    task_id=f"gx_{current_expectation_suite_name}-cp",
                    data_context_root_dir=gx_context_root_dir,
                    checkpoint_name=f"{current_expectation_suite_name}-checkpoint",
                    checkpoint_kwargs=f"{{{{ ti.xcom_pull(task_ids='{task_group_id}.load_templated_json')}}}}",
                    return_json_dict=True,
                    run_name="af-{{ ts_nodash }}-{{ task_instance.try_number }}",
                    fail_task_on_validation_failure=False,
                    retries=5,
                    retry_delay=3
                )

                load_templated_json(gx_validations) >> gx_anomalies >> [upload_data_docs_task, billing_estimate]