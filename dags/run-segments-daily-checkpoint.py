from airflow import DAG

from great_expectations_provider.operators.great_expectations import GreatExpectationsOperator
from great_expectations.core.batch import BatchRequest
from great_expectations.data_context.types.base import (
    DataContextConfig,
    CheckpointConfig
)

import great_expectations as gx
context = gx.get_context(context_root_dir="../great_expectations")

from datetime import date,datetime

PARTITION_DATE="2023-05-01"



with DAG(
    "gx_segs_activity_daily_constraints", 
    start_date=datetime(2023, 7 , 3), 
    schedule_interval='@daily', catchup=False
) as dag:

    gx_segs_activity_daily_constraints = GreatExpectationsOperator(
        task_id="gx_segs_activity_daily_constraints",
        data_context_root_dir="great_expectations",
        checkpoint_name='gfw-google-827.constraints.segs_activity_daily-checkpoint',
        checkpoint_kwargs={"validations":[
            {
                "batch_request": {"options": {"date": date.fromisoformat(PARTITION_DATE)}},
                "expectation_suite_name": "gfw-google-827.constraints.segs_activity_daily"
            }
        ]}
    )

    gx_segs_activity_daily_constraints
