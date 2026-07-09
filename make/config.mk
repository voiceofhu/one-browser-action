ACTION_REPOSITORY ?= voiceofhu/one-browser-action
ACTION_REF ?= main
GITHUB_API_URL ?= https://api.github.com
TAG ?=
VERSION_TAG ?= $(TAG)
DRY_RUN ?= false

SERVER_REPOSITORY ?= voiceofhu/one-browser-server
SERVER_REF ?=
WEB_REPOSITORY ?= voiceofhu/one-browser-web
WEB_REF ?= main
IMAGE_NAME ?= voiceofhu/one-browser-server
FORCE ?= false
DEPLOY ?= true

APP_REPOSITORY ?= voiceofhu/one-browser-app
APP_REF ?=

ifneq (,$(wildcard .env))
include .env
export
endif
