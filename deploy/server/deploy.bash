#!/usr/bin/env bash

set -ex

NAME=fabula

REPOROOT=$(git rev-parse --show-toplevel)
PROJECT=$(gcloud config get-value project)
SERVICE=$NAME
IMAGE=$NAME-image

# TODO: GCS bucket

# server in us-central1
gcloud builds submit $REPOROOT \
    --config $REPOROOT/deploy/server/cloudbuild.yaml \
    --substitutions=_IMAGE="$IMAGE"

gcloud run deploy $SERVICE \
    --image gcr.io/$PROJECT/$IMAGE \
    --set-env-vars=DB=$DB_STRING \
    --allow-unauthenticated \
    --region=us-central1 \
    --platform managed