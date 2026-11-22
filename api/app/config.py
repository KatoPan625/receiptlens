from functools import lru_cache

from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    db_host: str = "postgres"
    db_name: str = "receiptlens"
    db_user: str = "api_rw"
    db_password: str = ""
    s3_endpoint: str = "http://storage:8333"
    s3_key: str = ""
    s3_secret: str = ""
    s3_bucket: str = "receipts-raw"
    max_upload_mb: int = 10
    # Only the one-shot bootstrap job sets this: the password it gives the api_rw role.
    api_db_password: str = ""

    @property
    def database_url(self) -> str:
        return f"postgresql+psycopg://{self.db_user}:{self.db_password}@{self.db_host}/{self.db_name}"


@lru_cache
def get_settings() -> Settings:
    return Settings()
