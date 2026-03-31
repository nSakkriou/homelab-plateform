from __future__ import (absolute_import, division, print_function)
__metaclass__ = type


import os
from ansible.errors import AnsibleUndefinedVariable, AnsibleParserError, AnsibleConnectionFailure
from ansible.plugins.vars import BaseVarsPlugin

try:
    import boto3
    import botocore.exceptions
    HAS_BOTO3 = True
except ImportError:
    HAS_BOTO3 = False

DOCUMENTATION = '''
    name: read_terraform_state
    version_added: "2.10"  # for collections, use the collection version, not the Ansible version
    short_description: Read terraform state
    description: Loads ansible vars from remote terraform state 
    notes: 
        - requires boto3
'''

DIR = os.path.dirname(os.path.realpath(__file__))

CACHE = {}

class VarsModule(BaseVarsPlugin):

    """
    Loads variables for groups and/or hosts
    """

    def __init__(self, *args):
        super(VarsModule, self).__init__(*args)
        self.bucket_name = os.getenv('TF_BACKEND_BUCKET_NAME')
        err = []
        if (self.bucket_name is None):
            err.append('TF_BACKEND_BUCKET_NAME')
        CACHE['target'] = os.getenv('TF_TARGET')
        if (CACHE['target'] is None):
            err.append('TF_TARGET')
        self.aws_access_key_id = os.getenv('AWS_ACCESS_KEY_ID')
        if (self.aws_access_key_id is None):
            err.append('AWS_ACCESS_KEY_ID')
        self.aws_secret_access_key = os.getenv('AWS_SECRET_ACCESS_KEY')
        if (self.aws_secret_access_key is None):
            err.append('AWS_SECRET_ACCESS_KEY')
        self.aws_region = os.getenv('AWS_REGION')
        if (self.aws_region is None):
            err.append('AWS_REGION')
        if (len(err) > 0):
            raise AnsibleUndefinedVariable('Env variables missing: ' + (','.join(err)))
    def get_vars(self, loader, path, entities):
        if not HAS_BOTO3:
            raise AnsibleParserError('Vars plugin requires boto3')
        # Using cached value if necessary
        if ('result' in CACHE):
            return CACHE['result']
        else:
            print('Reading ansible_vars from remote Terraform state')
        try:
            # Call s3 and retrieve resource
            s3 = boto3.resource('s3',
                                aws_access_key_id = self.aws_access_key_id,
                                aws_secret_access_key = self.aws_secret_access_key,
                                region_name = self.aws_region)

            content_object = s3.Object(self.bucket_name, CACHE['target'])
            tfstate_content = content_object.get()['Body'].read().decode('utf-8')
            tfstate = loader.load(tfstate_content)
            ansible_vars = tfstate['outputs']['ansible_vars']['value']
            vars = loader.load(ansible_vars)
            CACHE['result'] = vars
            return CACHE['result']
        except Exception as err:
            raise AnsibleConnectionFailure(err)
