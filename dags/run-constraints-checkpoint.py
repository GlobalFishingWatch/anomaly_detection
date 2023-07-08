from airflow import DAG

import great_expectations as gx
from great_expectations_provider.operators.great_expectations import GreatExpectationsOperator

import logging
from datetime import date,datetime,timedelta
import os

import json
from airflow.decorators import task
import json
from jinja2 import Template

logger = logging.getLogger(__name__)

gx_context_root_dir=os.getenv('GX_CONTEXT_ROOT_DIR')
context = gx.get_context(context_root_dir=gx_context_root_dir)


with DAG(
    "gx_run_constraints_checkpoints", 
    start_date=datetime(2023, 7 , 3), 
    schedule_interval='@daily', catchup=False,
    render_template_as_native_obj=True
) as dag:
    
    @task
    def load_templated_json(checkpoint_kwargs_dict: dict, **context):
        json_template=json.dumps(checkpoint_kwargs_dict)
        logger.info(json_template)
        jinja_template = Template(json_template)
        rendered_json_str = jinja_template.render(**context)

        return json.loads(rendered_json_str)

    # TODO CHO20230705 Get date from airflow
    PARTITION_DATE=str(date.today() - timedelta(days=90))

    gx_datasource = context.get_datasource("gfw-google-827")
    
    # TODO CHO20230707 This is only robust as long as we have a 1:1 mapping of expectation suite to checkpoint
    for current_expectation_suite_name in [es for es in context.list_expectation_suite_names() if 'constraints' in es]:
        current_expectation_suite = context.get_expectation_suite(current_expectation_suite_name)
        if current_expectation_suite.expectations:
            current_expectation_suite_asset_name=current_expectation_suite.meta.get('asset_name')
            gx_asset=gx_datasource.get_asset(current_expectation_suite_asset_name)
            gx_splitter=gx_asset.splitter
            if gx_splitter is not None:
                DATE_PARTITION_COLUMN=gx_splitter.column_name
                # shift current date by dummy value because pipe3 is outdated
                br_options={DATE_PARTITION_COLUMN: "{{ macros.ds_add(ds, -80) }}"}
            else:
                br_options={}
            gx_br = {
                'batch_slice': None,
                'data_asset_name': gx_asset.name,
                'datasource_name': gx_datasource.name,
                'options': br_options
            }

            gx_validations = {'validations': [{"batch_request": gx_br}]}
            template_load_task_id=current_expectation_suite_name + '_load_template'
            gx_constraints = GreatExpectationsOperator(
                task_id=f"gx_{current_expectation_suite_name}-cp",
                data_context_root_dir=gx_context_root_dir,
                checkpoint_name=f"{current_expectation_suite_name}-checkpoint",
                checkpoint_kwargs=f"{{{{ ti.xcom_pull(task_ids='{template_load_task_id}')}}}}",
                return_json_dict=True
            )

            load_templated_json.override(task_id=template_load_task_id)(gx_validations) >> gx_constraints
