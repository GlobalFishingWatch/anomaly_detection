from airflow import DAG

from great_expectations_provider.operators.great_expectations import GreatExpectationsOperator
from great_expectations.core.batch import BatchRequest
from great_expectations.data_context.types.base import (
    DataContextConfig,
    CheckpointConfig
)

import logging

logger = logging.getLogger(__name__)

import great_expectations as gx
import os
gx_context_root_dir=os.getenv('GX_CONTEXT_ROOT_DIR')
context = gx.get_context(context_root_dir=gx_context_root_dir)

from datetime import date,datetime,timedelta


with DAG(
    "gx_segs_activity_daily_constraints", 
    start_date=datetime(2023, 7 , 3), 
    schedule_interval='@daily', catchup=False
) as dag:

    PARTITION_DATE=str(date.today() - timedelta(days=90))

    gx_datasource = context.get_datasource("gfw-google-827")
    
    for current_expectation_suite_name in [es for es in context.list_expectation_suite_names() if 'segs_activity_daily' in es and 'constraints' in es]:
        current_expectation_suite = context.get_expectation_suite(current_expectation_suite_name)
        current_expectation_suite_asset_name=current_expectation_suite.meta.get('asset_name')
        gx_asset=gx_datasource.get_asset(current_expectation_suite_asset_name)
        gx_splitter=gx_asset.splitter
        if gx_splitter is not None:
            DATE_PARTITION_COLUMN=gx_splitter.column_name
            br_options={DATE_PARTITION_COLUMN: PARTITION_DATE}
        else:
            br_options={}
        gx_br = gx_asset.build_batch_request(br_options)
        gx_cp = CheckpointConfig(
            name=f"{current_expectation_suite_name}-checkpoint",
            validations=[
                {
                "batch_request": gx_br
                }
            ],
            expectation_suite_name=current_expectation_suite_name
        )

        gx_validations = {
            'validations': [
                {
                "batch_request": gx_br
                }
            ]
        }


        PARTITIONTIME: '2023-04-07'
        gx_segs_activity_daily_constraints = GreatExpectationsOperator(
            task_id=f"gx_{current_expectation_suite_name}-cp",
            data_context_root_dir=gx_context_root_dir,
            checkpoint_name=f"{current_expectation_suite_name}-checkpoint",
            checkpoint_kwargs=gx_validations,
            return_json_dict=True
        )

        gx_segs_activity_daily_constraints
