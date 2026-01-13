"""
SAP BusinessObjects REST API Client

This module provides a Python wrapper for interacting with SAP BusinessObjects
REST Web Services API for automation purposes.
"""

import json
import logging
import time
from typing import Dict, List, Optional, Any
from dataclasses import dataclass
from urllib.parse import urljoin
import requests


# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


@dataclass
class BOBJSession:
    """Represents an authenticated BOBJ session."""
    server_url: str
    logon_token: str
    session_id: Optional[str] = None
    expires_at: Optional[float] = None


class BOBJClientError(Exception):
    """Base exception for BOBJ client errors."""
    pass


class AuthenticationError(BOBJClientError):
    """Raised when authentication fails."""
    pass


class APIError(BOBJClientError):
    """Raised when an API call fails."""
    pass


class BOBJClient:
    """
    Client for SAP BusinessObjects REST Web Services API.
    
    Provides methods for authentication, content management,
    and promotion operations.
    """
    
    DEFAULT_TIMEOUT = 60
    SESSION_TIMEOUT = 3600  # 1 hour
    
    def __init__(self, server_url: str, verify_ssl: bool = True):
        """
        Initialize the BOBJ client.
        
        Args:
            server_url: Base URL of the BOBJ server (e.g., http://bobj:8080)
            verify_ssl: Whether to verify SSL certificates
        """
        self.server_url = server_url.rstrip('/')
        self.verify_ssl = verify_ssl
        self.session: Optional[BOBJSession] = None
        self._http_session = requests.Session()
        
    def _api_url(self, endpoint: str) -> str:
        """Build full API URL."""
        return urljoin(self.server_url, f"/biprws/{endpoint.lstrip('/')}")
    
    def _get_headers(self, include_auth: bool = True) -> Dict[str, str]:
        """Build request headers."""
        headers = {
            'Accept': 'application/json',
            'Content-Type': 'application/json'
        }
        if include_auth and self.session:
            headers['X-SAP-LogonToken'] = self.session.logon_token
        return headers
    
    def authenticate(
        self,
        username: str,
        password: str,
        auth_type: str = 'secEnterprise'
    ) -> BOBJSession:
        """
        Authenticate to the BOBJ server.
        
        Args:
            username: BOBJ username
            password: BOBJ password
            auth_type: Authentication type (secEnterprise, secLDAP, secWinAD, secSAPR3)
            
        Returns:
            BOBJSession object with authentication details
            
        Raises:
            AuthenticationError: If authentication fails
        """
        logger.info(f"Authenticating to {self.server_url} as {username}")
        
        login_url = self._api_url('/logon/long')
        payload = {
            'userName': username,
            'password': password,
            'auth': auth_type
        }
        
        try:
            response = self._http_session.post(
                login_url,
                json=payload,
                headers=self._get_headers(include_auth=False),
                verify=self.verify_ssl,
                timeout=self.DEFAULT_TIMEOUT
            )
            
            if response.status_code == 200:
                data = response.json()
                logon_token = data.get('logonToken')
                
                if not logon_token:
                    raise AuthenticationError("No logon token in response")
                
                self.session = BOBJSession(
                    server_url=self.server_url,
                    logon_token=logon_token,
                    expires_at=time.time() + self.SESSION_TIMEOUT
                )
                
                logger.info("Authentication successful")
                return self.session
            else:
                raise AuthenticationError(f"Authentication failed: {response.status_code}")
                
        except requests.RequestException as e:
            raise AuthenticationError(f"Authentication request failed: {e}")
    
    def logout(self) -> None:
        """Log out and invalidate the current session."""
        if not self.session:
            return
            
        try:
            logout_url = self._api_url('/logoff')
            self._http_session.post(
                logout_url,
                headers=self._get_headers(),
                verify=self.verify_ssl,
                timeout=10
            )
            logger.info("Logged out successfully")
        except Exception as e:
            logger.warning(f"Logout failed: {e}")
        finally:
            self.session = None
    
    def get_folder_contents(
        self,
        folder_path: str = '/Public Folders'
    ) -> List[Dict[str, Any]]:
        """
        Get contents of a folder.
        
        Args:
            folder_path: Path to the folder
            
        Returns:
            List of objects in the folder
        """
        self._ensure_authenticated()
        
        url = self._api_url(f'/infostore/folder?path={folder_path}')
        
        try:
            response = self._http_session.get(
                url,
                headers=self._get_headers(),
                verify=self.verify_ssl,
                timeout=self.DEFAULT_TIMEOUT
            )
            
            if response.status_code == 200:
                return response.json().get('entries', [])
            else:
                raise APIError(f"Failed to get folder contents: {response.status_code}")
                
        except requests.RequestException as e:
            raise APIError(f"Request failed: {e}")
    
    def get_object_by_id(self, object_id: str) -> Dict[str, Any]:
        """
        Get an object by its ID.
        
        Args:
            object_id: The BOBJ object ID or CUID
            
        Returns:
            Object details
        """
        self._ensure_authenticated()
        
        url = self._api_url(f'/infostore/{object_id}')
        
        try:
            response = self._http_session.get(
                url,
                headers=self._get_headers(),
                verify=self.verify_ssl,
                timeout=self.DEFAULT_TIMEOUT
            )
            
            if response.status_code == 200:
                return response.json()
            elif response.status_code == 404:
                raise APIError(f"Object not found: {object_id}")
            else:
                raise APIError(f"Failed to get object: {response.status_code}")
                
        except requests.RequestException as e:
            raise APIError(f"Request failed: {e}")
    
    def create_promotion_job(
        self,
        name: str,
        source_path: str,
        include_security: bool = True,
        include_dependencies: bool = True
    ) -> str:
        """
        Create a promotion job for exporting content.
        
        Args:
            name: Name for the promotion job
            source_path: Path to export from
            include_security: Include security rights
            include_dependencies: Include dependent objects
            
        Returns:
            Job ID
        """
        self._ensure_authenticated()
        
        url = self._api_url('/lcm/promotions')
        payload = {
            'name': name,
            'sourcePath': source_path,
            'includeSecurityRights': include_security,
            'includeDependencies': include_dependencies,
            'exportType': 'LCMBIAR'
        }
        
        try:
            response = self._http_session.post(
                url,
                json=payload,
                headers=self._get_headers(),
                verify=self.verify_ssl,
                timeout=self.DEFAULT_TIMEOUT
            )
            
            if response.status_code in (200, 201):
                return response.json().get('id')
            else:
                raise APIError(f"Failed to create promotion job: {response.status_code}")
                
        except requests.RequestException as e:
            raise APIError(f"Request failed: {e}")
    
    def get_job_status(self, job_id: str) -> Dict[str, Any]:
        """
        Get the status of a promotion job.
        
        Args:
            job_id: The promotion job ID
            
        Returns:
            Job status details
        """
        self._ensure_authenticated()
        
        url = self._api_url(f'/lcm/promotions/{job_id}/status')
        
        try:
            response = self._http_session.get(
                url,
                headers=self._get_headers(),
                verify=self.verify_ssl,
                timeout=self.DEFAULT_TIMEOUT
            )
            
            if response.status_code == 200:
                return response.json()
            else:
                raise APIError(f"Failed to get job status: {response.status_code}")
                
        except requests.RequestException as e:
            raise APIError(f"Request failed: {e}")
    
    def wait_for_job(
        self,
        job_id: str,
        timeout: int = 300,
        poll_interval: int = 5
    ) -> Dict[str, Any]:
        """
        Wait for a job to complete.
        
        Args:
            job_id: The job ID to wait for
            timeout: Maximum time to wait in seconds
            poll_interval: Time between status checks
            
        Returns:
            Final job status
            
        Raises:
            APIError: If job fails or times out
        """
        start_time = time.time()
        
        while time.time() - start_time < timeout:
            status = self.get_job_status(job_id)
            state = status.get('state', 'Unknown')
            
            logger.info(f"Job {job_id} status: {state}")
            
            if state == 'Completed':
                return status
            elif state == 'Failed':
                raise APIError(f"Job failed: {status.get('errorMessage', 'Unknown error')}")
            
            time.sleep(poll_interval)
        
        raise APIError(f"Job timed out after {timeout} seconds")
    
    def test_connection(self) -> bool:
        """
        Test if the connection to the BOBJ server is working.
        
        Returns:
            True if connection is successful
        """
        try:
            response = self._http_session.get(
                self._api_url('/'),
                verify=self.verify_ssl,
                timeout=10
            )
            return response.status_code == 200
        except Exception:
            return False
    
    def _ensure_authenticated(self) -> None:
        """Ensure we have a valid session."""
        if not self.session:
            raise AuthenticationError("Not authenticated. Call authenticate() first.")
        
        if self.session.expires_at and time.time() > self.session.expires_at:
            raise AuthenticationError("Session expired. Re-authenticate required.")
    
    def __enter__(self):
        """Context manager entry."""
        return self
    
    def __exit__(self, exc_type, exc_val, exc_tb):
        """Context manager exit - ensure logout."""
        self.logout()


def create_client(
    server_url: str,
    username: str,
    password: str,
    auth_type: str = 'secEnterprise'
) -> BOBJClient:
    """
    Create and authenticate a BOBJ client.
    
    Args:
        server_url: BOBJ server URL
        username: Username
        password: Password
        auth_type: Authentication type
        
    Returns:
        Authenticated BOBJClient
    """
    client = BOBJClient(server_url)
    client.authenticate(username, password, auth_type)
    return client


if __name__ == '__main__':
    # Example usage
    import os
    
    server = os.environ.get('BOBJ_SERVER', 'http://localhost:8080')
    user = os.environ.get('BOBJ_USER', 'Administrator')
    password = os.environ.get('BOBJ_PASSWORD', '')
    
    if password:
        with BOBJClient(server) as client:
            client.authenticate(user, password)
            print(f"Connected to {server}")
    else:
        print("Set BOBJ_PASSWORD environment variable to test connection")
