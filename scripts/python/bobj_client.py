"""
SAP BusinessObjects Raylight REST API Client

Production-grade Python client for SAP BusinessObjects BI Platform
using the Raylight RESTful Web Services SDK (biprws/raylight/v1).

Supports:
- Authentication with session token management and auto-refresh
- Content discovery via Raylight v1 document/folder APIs
- Promotion Management for LCMBIAR export/import operations
- InfoStore queries for advanced object lookups
- Retry with exponential backoff on transient failures
- Server health checks via Raylight /about endpoint
"""

import json
import logging
import os
import time
import hashlib
from typing import Dict, List, Optional, Any, Tuple
from dataclasses import dataclass, field
from urllib.parse import urljoin, quote
from pathlib import Path

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry


logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s - %(message)s",
)
logger = logging.getLogger("bobj_raylight")


# ---------------------------------------------------------------------------
# Data classes
# ---------------------------------------------------------------------------

@dataclass
class BOBJSession:
    """Authenticated BOBJ session with token lifecycle tracking."""

    server_url: str
    logon_token: str
    serial_id: Optional[str] = None
    created_at: float = field(default_factory=time.time)
    expires_at: float = 0.0
    session_timeout: int = 3600  # default 1 h

    def __post_init__(self):
        if self.expires_at == 0.0:
            self.expires_at = self.created_at + self.session_timeout

    @property
    def is_expired(self) -> bool:
        return time.time() >= self.expires_at

    @property
    def remaining_seconds(self) -> float:
        return max(0.0, self.expires_at - time.time())


@dataclass
class PromotionJob:
    """Represents an LCM promotion job."""

    job_id: str
    name: str
    state: str = "Pending"
    lcmbiar_path: Optional[str] = None
    source_cms: Optional[str] = None
    destination_cms: Optional[str] = None
    created_at: Optional[str] = None
    completed_at: Optional[str] = None
    error_message: Optional[str] = None
    imported_count: int = 0
    skipped_count: int = 0
    failed_count: int = 0


# ---------------------------------------------------------------------------
# Exceptions
# ---------------------------------------------------------------------------

class BOBJClientError(Exception):
    """Base exception for BOBJ client errors."""


class AuthenticationError(BOBJClientError):
    """Authentication or session errors."""


class RaylightAPIError(BOBJClientError):
    """Raylight REST API call failures."""

    def __init__(self, message: str, status_code: int = 0, response_body: str = ""):
        super().__init__(message)
        self.status_code = status_code
        self.response_body = response_body


class PromotionError(BOBJClientError):
    """Promotion / LCM operation failures."""


class SessionExpiredError(AuthenticationError):
    """Session token has expired and needs refresh."""


# ---------------------------------------------------------------------------
# HTTP transport with retry
# ---------------------------------------------------------------------------

def _create_http_session(
    max_retries: int = 3,
    backoff_factor: float = 1.0,
    status_forcelist: Tuple[int, ...] = (502, 503, 504),
    verify_ssl: bool = True,
) -> requests.Session:
    """Create a requests.Session with retry + backoff on transient errors."""
    session = requests.Session()
    session.verify = verify_ssl

    retry_strategy = Retry(
        total=max_retries,
        backoff_factor=backoff_factor,
        status_forcelist=list(status_forcelist),
        allowed_methods=["GET", "POST", "PUT", "DELETE"],
        raise_on_status=False,
    )
    adapter = HTTPAdapter(max_retries=retry_strategy)
    session.mount("https://", adapter)
    session.mount("http://", adapter)
    return session


# ---------------------------------------------------------------------------
# Raylight REST API Client
# ---------------------------------------------------------------------------

class RaylightClient:
    """
    Production-grade client for SAP BusinessObjects Raylight REST API.

    Base paths:
        /biprws/logon/long          – authentication
        /biprws/logoff              – session teardown
        /biprws/raylight/v1/        – Raylight document & scheduling APIs
        /biprws/infostore/          – InfoStore CMS object queries
        /biprws/promotion/          – Promotion Management (LCM) APIs
    """

    RAYLIGHT_BASE = "/biprws/raylight/v1"
    INFOSTORE_BASE = "/biprws/infostore"
    PROMOTION_BASE = "/biprws/promotion"

    DEFAULT_TIMEOUT = 60
    SESSION_TIMEOUT = 3600          # 1 hour
    TOKEN_REFRESH_MARGIN = 300      # re-auth 5 min before expiry

    def __init__(
        self,
        server_url: str,
        verify_ssl: bool = True,
        max_retries: int = 3,
        backoff_factor: float = 1.0,
        request_timeout: int = DEFAULT_TIMEOUT,
    ):
        self.server_url = server_url.rstrip("/")
        self.verify_ssl = verify_ssl
        self.request_timeout = request_timeout
        self.session: Optional[BOBJSession] = None
        self._credentials: Optional[Dict[str, str]] = None
        self._http = _create_http_session(
            max_retries=max_retries,
            backoff_factor=backoff_factor,
            verify_ssl=verify_ssl,
        )

    # ------------------------------------------------------------------
    # URL builders
    # ------------------------------------------------------------------

    def _url(self, path: str) -> str:
        return f"{self.server_url}{path}"

    def _raylight_url(self, endpoint: str) -> str:
        return self._url(f"{self.RAYLIGHT_BASE}/{endpoint.lstrip('/')}")

    def _infostore_url(self, endpoint: str) -> str:
        return self._url(f"{self.INFOSTORE_BASE}/{endpoint.lstrip('/')}")

    def _promotion_url(self, endpoint: str = "") -> str:
        ep = f"/{endpoint.lstrip('/')}" if endpoint else ""
        return self._url(f"{self.PROMOTION_BASE}{ep}")

    # ------------------------------------------------------------------
    # Headers
    # ------------------------------------------------------------------

    def _headers(self, include_auth: bool = True, content_type: str = "application/json") -> Dict[str, str]:
        headers = {
            "Accept": "application/json",
            "Content-Type": content_type,
        }
        if include_auth and self.session:
            headers["X-SAP-LogonToken"] = f'"{self.session.logon_token}"'
        return headers

    # ------------------------------------------------------------------
    # Authentication
    # ------------------------------------------------------------------

    def authenticate(
        self,
        username: str,
        password: str,
        auth_type: str = "secEnterprise",
    ) -> BOBJSession:
        """
        Authenticate via /biprws/logon/long and obtain a logon token.

        Args:
            username: BOBJ account
            password: BOBJ password
            auth_type: secEnterprise | secLDAP | secWinAD | secSAPR3
        """
        logger.info("Authenticating to %s as '%s' (auth=%s)", self.server_url, username, auth_type)

        # Store credentials for auto-refresh
        self._credentials = {
            "userName": username,
            "password": password,
            "auth": auth_type,
        }

        url = self._url("/biprws/logon/long")
        payload = json.dumps(self._credentials)

        try:
            resp = self._http.post(
                url,
                data=payload,
                headers=self._headers(include_auth=False),
                timeout=self.request_timeout,
            )
        except requests.RequestException as exc:
            raise AuthenticationError(f"Connection to {self.server_url} failed: {exc}") from exc

        if resp.status_code != 200:
            raise AuthenticationError(
                f"Authentication failed – HTTP {resp.status_code}: {resp.text[:500]}"
            )

        data = resp.json()
        logon_token = data.get("logonToken")
        if not logon_token:
            raise AuthenticationError("Server returned 200 but no logonToken in body")

        self.session = BOBJSession(
            server_url=self.server_url,
            logon_token=logon_token,
            serial_id=data.get("serialId"),
            session_timeout=self.SESSION_TIMEOUT,
        )
        logger.info("Authenticated – token valid for %ds", self.SESSION_TIMEOUT)
        return self.session

    def _ensure_session(self) -> None:
        """Validate session, auto-refresh if nearing expiry."""
        if not self.session:
            raise AuthenticationError("Not authenticated – call authenticate() first")

        if self.session.remaining_seconds < self.TOKEN_REFRESH_MARGIN:
            logger.info("Session nearing expiry (%.0fs left), refreshing...", self.session.remaining_seconds)
            if self._credentials:
                self.logout()
                self.authenticate(**{
                    "username": self._credentials["userName"],
                    "password": self._credentials["password"],
                    "auth_type": self._credentials["auth"],
                })
            else:
                raise SessionExpiredError("Session expired and no credentials stored for refresh")

    def logout(self) -> None:
        """Logoff and invalidate the session token."""
        if not self.session:
            return
        try:
            self._http.post(
                self._url("/biprws/logoff"),
                headers=self._headers(),
                timeout=10,
            )
            logger.info("Session logged off")
        except Exception as exc:
            logger.warning("Logoff request failed: %s", exc)
        finally:
            self.session = None

    # ------------------------------------------------------------------
    # Health / Server Info  (Raylight /about)
    # ------------------------------------------------------------------

    def get_server_info(self) -> Dict[str, Any]:
        """
        GET /biprws/raylight/v1/about
        Returns server version, build, product name.
        """
        self._ensure_session()
        resp = self._http.get(
            self._raylight_url("about"),
            headers=self._headers(),
            timeout=self.request_timeout,
        )
        if resp.status_code != 200:
            raise RaylightAPIError("Failed to get server info", resp.status_code, resp.text)
        return resp.json()

    def health_check(self) -> Dict[str, Any]:
        """
        Perform a lightweight connectivity + Raylight API health check.
        Returns dict with status, latency, and server version.
        """
        result: Dict[str, Any] = {"healthy": False, "latency_ms": 0, "server_version": None, "error": None}
        start = time.time()
        try:
            # 1) Basic HTTP
            resp = self._http.get(self._url("/biprws"), timeout=10)
            result["latency_ms"] = int((time.time() - start) * 1000)

            if resp.status_code != 200:
                result["error"] = f"biprws returned HTTP {resp.status_code}"
                return result

            # 2) Raylight about (requires auth)
            if self.session:
                info = self.get_server_info()
                result["server_version"] = info.get("productVersion") or info.get("version")

            result["healthy"] = True
        except Exception as exc:
            result["error"] = str(exc)
            result["latency_ms"] = int((time.time() - start) * 1000)

        return result

    # ------------------------------------------------------------------
    # Raylight Document APIs
    # ------------------------------------------------------------------

    def list_documents(
        self,
        folder_id: Optional[str] = None,
        document_type: Optional[str] = None,
        offset: int = 0,
        limit: int = 50,
    ) -> Dict[str, Any]:
        """
        GET /biprws/raylight/v1/documents
        Retrieve documents, optionally filtered by folder or type.
        """
        self._ensure_session()
        params: Dict[str, Any] = {"offset": offset, "limit": limit}
        if folder_id:
            params["folderId"] = folder_id
        if document_type:
            params["type"] = document_type

        resp = self._http.get(
            self._raylight_url("documents"),
            headers=self._headers(),
            params=params,
            timeout=self.request_timeout,
        )
        if resp.status_code != 200:
            raise RaylightAPIError("list_documents failed", resp.status_code, resp.text)
        return resp.json()

    def get_document(self, doc_id: str) -> Dict[str, Any]:
        """GET /biprws/raylight/v1/documents/{id}"""
        self._ensure_session()
        resp = self._http.get(
            self._raylight_url(f"documents/{doc_id}"),
            headers=self._headers(),
            timeout=self.request_timeout,
        )
        if resp.status_code == 404:
            raise RaylightAPIError(f"Document {doc_id} not found", 404)
        if resp.status_code != 200:
            raise RaylightAPIError("get_document failed", resp.status_code, resp.text)
        return resp.json()

    def get_document_schedules(self, doc_id: str) -> List[Dict[str, Any]]:
        """GET /biprws/raylight/v1/documents/{id}/schedules"""
        self._ensure_session()
        resp = self._http.get(
            self._raylight_url(f"documents/{doc_id}/schedules"),
            headers=self._headers(),
            timeout=self.request_timeout,
        )
        if resp.status_code != 200:
            raise RaylightAPIError("get_document_schedules failed", resp.status_code, resp.text)
        return resp.json().get("schedules", [])

    # ------------------------------------------------------------------
    # InfoStore Queries (CMS object lookup)
    # ------------------------------------------------------------------

    def infostore_query(self, query: str) -> List[Dict[str, Any]]:
        """
        GET /biprws/infostore/cuid_lookup?query=<CMS query>
        Execute an InfoStore query for CMS objects.
        """
        self._ensure_session()
        resp = self._http.get(
            self._infostore_url("cuid_lookup"),
            headers=self._headers(),
            params={"query": query},
            timeout=self.request_timeout,
        )
        if resp.status_code != 200:
            raise RaylightAPIError("infostore_query failed", resp.status_code, resp.text)
        return resp.json().get("entries", [])

    def get_folder_by_path(self, folder_path: str) -> Dict[str, Any]:
        """
        GET /biprws/infostore/folder?path=<encoded path>
        Resolve a folder path to its InfoStore object.
        """
        self._ensure_session()
        resp = self._http.get(
            self._infostore_url("folder"),
            headers=self._headers(),
            params={"path": folder_path},
            timeout=self.request_timeout,
        )
        if resp.status_code != 200:
            raise RaylightAPIError(f"Folder not found: {folder_path}", resp.status_code, resp.text)
        return resp.json()

    def get_folder_children(self, folder_id: str, offset: int = 0, limit: int = 100) -> List[Dict[str, Any]]:
        """
        GET /biprws/infostore/{folder_id}/children
        List child objects of a folder.
        """
        self._ensure_session()
        resp = self._http.get(
            self._infostore_url(f"{folder_id}/children"),
            headers=self._headers(),
            params={"offset": offset, "limit": limit},
            timeout=self.request_timeout,
        )
        if resp.status_code != 200:
            raise RaylightAPIError("get_folder_children failed", resp.status_code, resp.text)
        return resp.json().get("entries", [])

    def get_object_by_cuid(self, cuid: str) -> Dict[str, Any]:
        """
        GET /biprws/infostore/cuid_{cuid}
        Retrieve a CMS object by CUID.
        """
        self._ensure_session()
        resp = self._http.get(
            self._infostore_url(f"cuid_{cuid}"),
            headers=self._headers(),
            timeout=self.request_timeout,
        )
        if resp.status_code == 404:
            raise RaylightAPIError(f"Object CUID {cuid} not found", 404)
        if resp.status_code != 200:
            raise RaylightAPIError("get_object_by_cuid failed", resp.status_code, resp.text)
        return resp.json()

    def get_object_by_id(self, si_id: str) -> Dict[str, Any]:
        """
        GET /biprws/infostore/{si_id}
        Retrieve a CMS object by SI_ID.
        """
        self._ensure_session()
        resp = self._http.get(
            self._infostore_url(str(si_id)),
            headers=self._headers(),
            timeout=self.request_timeout,
        )
        if resp.status_code == 404:
            raise RaylightAPIError(f"Object SI_ID {si_id} not found", 404)
        if resp.status_code != 200:
            raise RaylightAPIError("get_object_by_id failed", resp.status_code, resp.text)
        return resp.json()

    # ------------------------------------------------------------------
    # Promotion Management API – LCMBIAR Export
    # ------------------------------------------------------------------

    def create_promotion_job(
        self,
        job_name: str,
        source_folder: str,
        include_security: bool = True,
        include_dependencies: bool = True,
        include_connections: bool = True,
        object_cuid_list: Optional[List[str]] = None,
    ) -> PromotionJob:
        """
        POST /biprws/promotion/
        Create an LCM promotion job to export content to LCMBIAR.
        """
        self._ensure_session()

        payload: Dict[str, Any] = {
            "attrs": {
                "name": job_name,
                "description": f"Automated export – {job_name}",
                "lcmType": "export",
                "sourceFolder": source_folder,
                "exportFormat": "lcmbiar",
                "options": {
                    "includeSecurityRights": include_security,
                    "includeDependencies": include_dependencies,
                    "includeConnections": include_connections,
                    "overwriteExisting": True,
                },
            }
        }

        if object_cuid_list:
            payload["attrs"]["objectCUIDs"] = object_cuid_list

        resp = self._http.post(
            self._promotion_url(),
            data=json.dumps(payload),
            headers=self._headers(),
            timeout=self.request_timeout,
        )

        if resp.status_code not in (200, 201):
            raise PromotionError(
                f"Failed to create promotion job: HTTP {resp.status_code} – {resp.text[:500]}"
            )

        data = resp.json()
        job = PromotionJob(
            job_id=str(data.get("id", data.get("si_id", ""))),
            name=job_name,
            state=data.get("state", "Created"),
            created_at=data.get("createdAt"),
            source_cms=self.server_url,
        )
        logger.info("Promotion job created: id=%s name=%s", job.job_id, job.name)
        return job

    def test_promotion(self, job_id: str) -> Dict[str, Any]:
        """
        POST /biprws/promotion/{id}/test
        Run a test (dry-run) of the promotion job.
        """
        self._ensure_session()
        resp = self._http.post(
            self._promotion_url(f"{job_id}/test"),
            headers=self._headers(),
            timeout=self.request_timeout,
        )
        if resp.status_code != 200:
            raise PromotionError(f"Promotion test failed: HTTP {resp.status_code}")
        return resp.json()

    def execute_promotion(self, job_id: str) -> Dict[str, Any]:
        """
        POST /biprws/promotion/{id}/promote
        Execute the promotion job (actual export).
        """
        self._ensure_session()
        resp = self._http.post(
            self._promotion_url(f"{job_id}/promote"),
            headers=self._headers(),
            timeout=self.request_timeout,
        )
        if resp.status_code not in (200, 202):
            raise PromotionError(f"Promotion execution failed: HTTP {resp.status_code} – {resp.text[:500]}")
        return resp.json()

    def get_promotion_status(self, job_id: str) -> Dict[str, Any]:
        """
        GET /biprws/promotion/{id}
        Get current status of a promotion job.
        """
        self._ensure_session()
        resp = self._http.get(
            self._promotion_url(job_id),
            headers=self._headers(),
            timeout=self.request_timeout,
        )
        if resp.status_code != 200:
            raise PromotionError(f"Failed to get promotion status: HTTP {resp.status_code}")
        return resp.json()

    def wait_for_promotion(
        self,
        job_id: str,
        timeout_seconds: int = 1800,
        poll_interval: int = 10,
    ) -> PromotionJob:
        """
        Poll promotion job until completion, failure, or timeout.
        """
        deadline = time.time() + timeout_seconds
        last_state = ""

        while time.time() < deadline:
            self._ensure_session()
            status = self.get_promotion_status(job_id)
            state = status.get("state", "Unknown")

            if state != last_state:
                logger.info("Promotion %s state: %s", job_id, state)
                last_state = state

            if state in ("Completed", "Success"):
                return PromotionJob(
                    job_id=job_id,
                    name=status.get("name", ""),
                    state="Completed",
                    completed_at=status.get("completedAt"),
                    imported_count=status.get("importedCount", 0),
                    skipped_count=status.get("skippedCount", 0),
                    failed_count=status.get("failedCount", 0),
                )
            elif state in ("Failed", "Error"):
                raise PromotionError(
                    f"Promotion job {job_id} failed: {status.get('errorMessage', 'Unknown error')}"
                )

            time.sleep(poll_interval)

        raise PromotionError(f"Promotion job {job_id} timed out after {timeout_seconds}s")

    def download_lcmbiar(self, job_id: str, output_dir: str) -> str:
        """
        GET /biprws/promotion/{id}/lcmbiar
        Download the LCMBIAR archive produced by a promotion job.
        """
        self._ensure_session()
        output_path = Path(output_dir)
        output_path.mkdir(parents=True, exist_ok=True)

        resp = self._http.get(
            self._promotion_url(f"{job_id}/lcmbiar"),
            headers={
                "X-SAP-LogonToken": f'"{self.session.logon_token}"',
                "Accept": "application/octet-stream",
            },
            stream=True,
            timeout=300,
        )

        if resp.status_code != 200:
            raise PromotionError(f"LCMBIAR download failed: HTTP {resp.status_code}")

        # Derive filename from Content-Disposition or generate one
        filename = None
        cd = resp.headers.get("Content-Disposition", "")
        if "filename=" in cd:
            filename = cd.split("filename=")[-1].strip('" ')
        if not filename:
            filename = f"export_{job_id}_{int(time.time())}.lcmbiar"

        file_path = str(output_path / filename)
        sha256 = hashlib.sha256()
        total_bytes = 0

        with open(file_path, "wb") as fh:
            for chunk in resp.iter_content(chunk_size=8192):
                if chunk:
                    fh.write(chunk)
                    sha256.update(chunk)
                    total_bytes += len(chunk)

        logger.info(
            "LCMBIAR downloaded: %s (%d bytes, sha256=%s)",
            file_path, total_bytes, sha256.hexdigest()[:16],
        )
        return file_path

    # ------------------------------------------------------------------
    # Promotion Management API – LCMBIAR Import
    # ------------------------------------------------------------------

    def upload_lcmbiar(
        self,
        lcmbiar_path: str,
        conflict_resolution: str = "overwrite",
        overwrite_security: bool = False,
        target_folder: Optional[str] = None,
    ) -> PromotionJob:
        """
        POST /biprws/promotion/
        Upload and import an LCMBIAR file to the target CMS.

        conflict_resolution: overwrite | skip | rename | fail
        """
        self._ensure_session()

        file_path = Path(lcmbiar_path)
        if not file_path.exists():
            raise PromotionError(f"LCMBIAR file not found: {lcmbiar_path}")

        file_size = file_path.stat().st_size
        logger.info("Uploading LCMBIAR: %s (%d bytes)", file_path.name, file_size)

        # Build multipart form upload
        with open(lcmbiar_path, "rb") as fh:
            files = {
                "file": (file_path.name, fh, "application/octet-stream"),
            }
            form_data = {
                "lcmType": "import",
                "conflictResolution": conflict_resolution,
                "overwriteSecurity": str(overwrite_security).lower(),
            }
            if target_folder:
                form_data["targetFolder"] = target_folder

            headers = {
                "X-SAP-LogonToken": f'"{self.session.logon_token}"',
                "Accept": "application/json",
            }

            resp = self._http.post(
                self._promotion_url(),
                files=files,
                data=form_data,
                headers=headers,
                timeout=600,  # large files need longer timeout
            )

        if resp.status_code not in (200, 201, 202):
            raise PromotionError(
                f"LCMBIAR upload failed: HTTP {resp.status_code} – {resp.text[:500]}"
            )

        data = resp.json()
        job = PromotionJob(
            job_id=str(data.get("id", data.get("si_id", ""))),
            name=data.get("name", file_path.stem),
            state=data.get("state", "Submitted"),
            destination_cms=self.server_url,
        )
        logger.info("Import job created: id=%s", job.job_id)
        return job

    def get_import_results(self, job_id: str) -> Dict[str, Any]:
        """
        GET /biprws/promotion/{id}/results
        Retrieve detailed import results (counts, errors).
        """
        self._ensure_session()
        resp = self._http.get(
            self._promotion_url(f"{job_id}/results"),
            headers=self._headers(),
            timeout=self.request_timeout,
        )
        if resp.status_code != 200:
            raise PromotionError(f"Failed to get import results: HTTP {resp.status_code}")
        return resp.json()

    # ------------------------------------------------------------------
    # High-level convenience methods
    # ------------------------------------------------------------------

    def export_folder_to_lcmbiar(
        self,
        folder_path: str,
        output_dir: str,
        job_name: Optional[str] = None,
        include_security: bool = True,
        include_dependencies: bool = True,
        include_connections: bool = True,
        timeout_seconds: int = 1800,
        dry_run: bool = False,
    ) -> Tuple[PromotionJob, str]:
        """
        End-to-end: create promotion job -> (optional dry run) -> execute -> poll -> download LCMBIAR.

        Returns (PromotionJob, lcmbiar_file_path).
        """
        if not job_name:
            job_name = f"Export_{int(time.time())}"

        # 1. Create job
        job = self.create_promotion_job(
            job_name=job_name,
            source_folder=folder_path,
            include_security=include_security,
            include_dependencies=include_dependencies,
            include_connections=include_connections,
        )

        # 2. Optional dry-run
        if dry_run:
            logger.info("Running promotion test (dry-run)...")
            test_result = self.test_promotion(job.job_id)
            logger.info("Dry-run result: %s", json.dumps(test_result, indent=2)[:500])

        # 3. Execute
        self.execute_promotion(job.job_id)

        # 4. Wait for completion
        completed_job = self.wait_for_promotion(job.job_id, timeout_seconds=timeout_seconds)

        # 5. Download LCMBIAR
        lcmbiar_path = self.download_lcmbiar(job.job_id, output_dir)

        return completed_job, lcmbiar_path

    def import_lcmbiar_to_env(
        self,
        lcmbiar_path: str,
        conflict_resolution: str = "overwrite",
        overwrite_security: bool = False,
        target_folder: Optional[str] = None,
        timeout_seconds: int = 1800,
    ) -> PromotionJob:
        """
        End-to-end: upload LCMBIAR -> poll -> return results.
        """
        # 1. Upload
        job = self.upload_lcmbiar(
            lcmbiar_path=lcmbiar_path,
            conflict_resolution=conflict_resolution,
            overwrite_security=overwrite_security,
            target_folder=target_folder,
        )

        # 2. Wait for completion
        completed_job = self.wait_for_promotion(job.job_id, timeout_seconds=timeout_seconds)

        # 3. Fetch detailed results
        try:
            results = self.get_import_results(job.job_id)
            completed_job.imported_count = results.get("importedCount", 0)
            completed_job.skipped_count = results.get("skippedCount", 0)
            completed_job.failed_count = results.get("failedCount", 0)
        except Exception as exc:
            logger.warning("Could not fetch import results: %s", exc)

        return completed_job

    def verify_objects_exist(self, cuid_list: List[str]) -> Dict[str, bool]:
        """
        Verify a list of CUIDs exist on this CMS (for post-deployment checks).
        Returns {cuid: exists_bool}.
        """
        self._ensure_session()
        result = {}
        for cuid in cuid_list:
            try:
                self.get_object_by_cuid(cuid)
                result[cuid] = True
            except RaylightAPIError:
                result[cuid] = False
        return result

    # ------------------------------------------------------------------
    # Context manager
    # ------------------------------------------------------------------

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.logout()


# ---------------------------------------------------------------------------
# Factory helper
# ---------------------------------------------------------------------------

def create_client(
    server_url: str,
    username: str,
    password: str,
    auth_type: str = "secEnterprise",
    verify_ssl: bool = True,
    max_retries: int = 3,
) -> RaylightClient:
    """Create and authenticate a RaylightClient."""
    client = RaylightClient(server_url, verify_ssl=verify_ssl, max_retries=max_retries)
    client.authenticate(username, password, auth_type)
    return client


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="BOBJ Raylight REST API Client")
    parser.add_argument("--server", required=True, help="BOBJ server URL")
    parser.add_argument("--user", required=True, help="Username")
    parser.add_argument("--password", required=True, help="Password")
    parser.add_argument("--auth-type", default="secEnterprise")
    parser.add_argument("--action", choices=["health", "export", "import", "list"], default="health")
    parser.add_argument("--folder", default="/Public Folders")
    parser.add_argument("--output", default="./output")
    parser.add_argument("--lcmbiar", help="LCMBIAR file for import")
    parser.add_argument("--conflict", default="overwrite", choices=["overwrite", "skip", "rename", "fail"])
    parser.add_argument("--no-ssl-verify", action="store_true")
    args = parser.parse_args()

    with RaylightClient(args.server, verify_ssl=not args.no_ssl_verify) as client:
        client.authenticate(args.user, args.password, args.auth_type)

        if args.action == "health":
            result = client.health_check()
            print(json.dumps(result, indent=2))

        elif args.action == "list":
            folder = client.get_folder_by_path(args.folder)
            print(json.dumps(folder, indent=2))

        elif args.action == "export":
            job, path = client.export_folder_to_lcmbiar(args.folder, args.output)
            print(f"Export complete: {path}")
            print(f"Job: {job.job_id} State: {job.state}")

        elif args.action == "import":
            if not args.lcmbiar:
                parser.error("--lcmbiar required for import action")
            job = client.import_lcmbiar_to_env(args.lcmbiar, conflict_resolution=args.conflict)
            print(f"Import complete: {job.job_id}")
            print(f"Imported: {job.imported_count} Skipped: {job.skipped_count} Failed: {job.failed_count}")
