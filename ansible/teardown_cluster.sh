#!/bin/bash
if [ -z ${ANSIBLE_PYTHON_INTERPRETER} ]; then
  ansible-playbook -i inventories/k8s_${ENV}.ini cluster-teardown.yml --connection=local
else
  ansible-playbook -i inventories/k8s_${ENV}.ini cluster-teardown.yml --connection=local -e "ansible_python_interpreter=$ANSIBLE_PYTHON_INTERPRETER"
fi
