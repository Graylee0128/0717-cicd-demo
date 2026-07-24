import os

from fastapi import FastAPI


VERSION = os.getenv("APP_VERSION", "dev")
app = FastAPI(title="0717 CI/CD Demo")


@app.get("/")
def root():
    return {"service": "0717-cicd-demo", "version": VERSION, "build": "v9"}


@app.get("/health")
def health():
    return {"status": "ok"}
