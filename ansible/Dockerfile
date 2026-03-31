FROM alpine:3.16.2

RUN apk update && apk add

RUN apk add curl
RUN apk add openssl

RUN curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
RUN chmod 700 get_helm.sh
RUN /bin/sh get_helm.sh

RUN curl -LO https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl
RUN chmod +x ./kubectl
RUN mv ./kubectl /bin/kubectl

RUN apk add python3
RUN apk add py3-pip

RUN apk add ansible
COPY ansible ansible

RUN curl -LO https://github.com/argoproj/argo-cd/releases/download/v2.4.7/argocd-linux-amd64
RUN chmod +x ./argocd-linux-amd64
RUN mv ./argocd-linux-amd64 /bin/argocd

RUN pip install -r ansible/python_dependencies.txt
RUN ansible-galaxy install -r ansible/requirements.yml

