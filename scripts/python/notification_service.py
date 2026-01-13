"""
Notification Service for BOBJ CI/CD Pipeline

This module provides notification functionality for sending pipeline
status updates to Teams, Email, and other channels.
"""

import json
import logging
import os
from dataclasses import dataclass, asdict
from typing import Optional, List, Dict
from datetime import datetime
import requests


logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)


@dataclass
class NotificationMessage:
    """Represents a notification message."""
    title: str
    message: str
    status: str  # success, warning, error, info
    environment: Optional[str] = None
    build_id: Optional[str] = None
    pipeline: Optional[str] = None
    timestamp: Optional[str] = None
    details: Optional[Dict] = None
    
    def __post_init__(self):
        if not self.timestamp:
            self.timestamp = datetime.utcnow().strftime('%Y-%m-%d %H:%M:%S UTC')


class TeamsNotifier:
    """Send notifications to Microsoft Teams via webhook."""
    
    STATUS_COLORS = {
        'success': '28A745',
        'warning': 'FFC107',
        'error': 'DC3545',
        'info': '0078D7'
    }
    
    STATUS_ICONS = {
        'success': '✅',
        'warning': '⚠️',
        'error': '❌',
        'info': 'ℹ️'
    }
    
    def __init__(self, webhook_url: str):
        """
        Initialize Teams notifier.
        
        Args:
            webhook_url: Teams incoming webhook URL
        """
        self.webhook_url = webhook_url
    
    def send(self, notification: NotificationMessage) -> bool:
        """
        Send a notification to Teams.
        
        Args:
            notification: NotificationMessage to send
            
        Returns:
            True if sent successfully
        """
        color = self.STATUS_COLORS.get(notification.status, '0078D7')
        icon = self.STATUS_ICONS.get(notification.status, 'ℹ️')
        
        facts = []
        if notification.build_id:
            facts.append({'name': 'Build ID', 'value': notification.build_id})
        if notification.pipeline:
            facts.append({'name': 'Pipeline', 'value': notification.pipeline})
        if notification.environment:
            facts.append({'name': 'Environment', 'value': notification.environment})
        if notification.timestamp:
            facts.append({'name': 'Timestamp', 'value': notification.timestamp})
        
        payload = {
            '@type': 'MessageCard',
            '@context': 'http://schema.org/extensions',
            'themeColor': color,
            'summary': notification.title,
            'sections': [
                {
                    'activityTitle': f'{icon} {notification.title}',
                    'facts': facts,
                    'text': notification.message,
                    'markdown': True
                }
            ]
        }
        
        # Add action button if details contain a URL
        if notification.details and notification.details.get('pipeline_url'):
            payload['potentialAction'] = [
                {
                    '@type': 'OpenUri',
                    'name': 'View Pipeline',
                    'targets': [
                        {'os': 'default', 'uri': notification.details['pipeline_url']}
                    ]
                }
            ]
        
        try:
            response = requests.post(
                self.webhook_url,
                json=payload,
                headers={'Content-Type': 'application/json'},
                timeout=30
            )
            
            if response.status_code == 200:
                logger.info(f"Teams notification sent: {notification.title}")
                return True
            else:
                logger.error(f"Teams notification failed: {response.status_code}")
                return False
                
        except Exception as e:
            logger.error(f"Failed to send Teams notification: {e}")
            return False


class EmailNotifier:
    """Send notifications via SMTP email."""
    
    def __init__(
        self,
        smtp_host: str,
        smtp_port: int = 587,
        username: Optional[str] = None,
        password: Optional[str] = None,
        from_address: Optional[str] = None
    ):
        """
        Initialize email notifier.
        
        Args:
            smtp_host: SMTP server hostname
            smtp_port: SMTP server port
            username: SMTP username (optional)
            password: SMTP password (optional)
            from_address: From email address
        """
        self.smtp_host = smtp_host
        self.smtp_port = smtp_port
        self.username = username
        self.password = password
        self.from_address = from_address or f'bobj-automation@{smtp_host}'
    
    def send(
        self,
        notification: NotificationMessage,
        recipients: List[str]
    ) -> bool:
        """
        Send a notification via email.
        
        Args:
            notification: NotificationMessage to send
            recipients: List of email addresses
            
        Returns:
            True if sent successfully
        """
        import smtplib
        from email.mime.text import MIMEText
        from email.mime.multipart import MIMEMultipart
        
        status_emoji = {
            'success': '✅',
            'warning': '⚠️',
            'error': '❌',
            'info': 'ℹ️'
        }
        
        emoji = status_emoji.get(notification.status, 'ℹ️')
        subject = f'{emoji} [{notification.status.upper()}] {notification.title}'
        
        # Build HTML body
        html_body = f"""
        <html>
        <body style="font-family: Arial, sans-serif;">
            <h2 style="color: #333;">{emoji} {notification.title}</h2>
            <p>{notification.message}</p>
            <table style="border-collapse: collapse; margin: 20px 0;">
                <tr>
                    <td style="padding: 8px; border: 1px solid #ddd;"><strong>Status</strong></td>
                    <td style="padding: 8px; border: 1px solid #ddd;">{notification.status.upper()}</td>
                </tr>
        """
        
        if notification.build_id:
            html_body += f"""
                <tr>
                    <td style="padding: 8px; border: 1px solid #ddd;"><strong>Build ID</strong></td>
                    <td style="padding: 8px; border: 1px solid #ddd;">{notification.build_id}</td>
                </tr>
            """
        
        if notification.environment:
            html_body += f"""
                <tr>
                    <td style="padding: 8px; border: 1px solid #ddd;"><strong>Environment</strong></td>
                    <td style="padding: 8px; border: 1px solid #ddd;">{notification.environment}</td>
                </tr>
            """
        
        if notification.timestamp:
            html_body += f"""
                <tr>
                    <td style="padding: 8px; border: 1px solid #ddd;"><strong>Timestamp</strong></td>
                    <td style="padding: 8px; border: 1px solid #ddd;">{notification.timestamp}</td>
                </tr>
            """
        
        html_body += """
            </table>
            <p style="color: #666; font-size: 12px;">
                This is an automated message from the BOBJ CI/CD Pipeline.
            </p>
        </body>
        </html>
        """
        
        msg = MIMEMultipart('alternative')
        msg['Subject'] = subject
        msg['From'] = self.from_address
        msg['To'] = ', '.join(recipients)
        msg.attach(MIMEText(html_body, 'html'))
        
        try:
            with smtplib.SMTP(self.smtp_host, self.smtp_port) as server:
                server.starttls()
                if self.username and self.password:
                    server.login(self.username, self.password)
                server.sendmail(self.from_address, recipients, msg.as_string())
            
            logger.info(f"Email notification sent to {len(recipients)} recipients")
            return True
            
        except Exception as e:
            logger.error(f"Failed to send email notification: {e}")
            return False


class NotificationService:
    """
    Unified notification service supporting multiple channels.
    """
    
    def __init__(self):
        """Initialize notification service from environment variables."""
        self.teams_notifier = None
        self.email_notifier = None
        
        # Initialize Teams if webhook URL is set
        teams_webhook = os.environ.get('TEAMS_WEBHOOK_URL')
        if teams_webhook:
            self.teams_notifier = TeamsNotifier(teams_webhook)
            logger.info("Teams notifier initialized")
        
        # Initialize Email if SMTP settings are set
        smtp_host = os.environ.get('SMTP_HOST')
        if smtp_host:
            self.email_notifier = EmailNotifier(
                smtp_host=smtp_host,
                smtp_port=int(os.environ.get('SMTP_PORT', 587)),
                username=os.environ.get('SMTP_USERNAME'),
                password=os.environ.get('SMTP_PASSWORD'),
                from_address=os.environ.get('SMTP_FROM')
            )
            logger.info("Email notifier initialized")
    
    def send(
        self,
        notification: NotificationMessage,
        channels: Optional[List[str]] = None,
        email_recipients: Optional[List[str]] = None
    ) -> Dict[str, bool]:
        """
        Send notification to specified channels.
        
        Args:
            notification: NotificationMessage to send
            channels: List of channels ('teams', 'email')
            email_recipients: Email recipients (required if email channel)
            
        Returns:
            Dict of channel -> success status
        """
        if channels is None:
            channels = ['teams']
        
        results = {}
        
        if 'teams' in channels and self.teams_notifier:
            results['teams'] = self.teams_notifier.send(notification)
        
        if 'email' in channels and self.email_notifier and email_recipients:
            results['email'] = self.email_notifier.send(notification, email_recipients)
        
        return results


def send_pipeline_notification(
    title: str,
    message: str,
    status: str,
    environment: Optional[str] = None,
    build_id: Optional[str] = None,
    pipeline: Optional[str] = None
) -> bool:
    """
    Convenience function to send a pipeline notification.
    
    Args:
        title: Notification title
        message: Notification message
        status: Status (success, warning, error, info)
        environment: Target environment
        build_id: Build ID
        pipeline: Pipeline name
        
    Returns:
        True if notification sent successfully
    """
    notification = NotificationMessage(
        title=title,
        message=message,
        status=status,
        environment=environment,
        build_id=build_id,
        pipeline=pipeline
    )
    
    service = NotificationService()
    results = service.send(notification)
    
    return any(results.values())


if __name__ == '__main__':
    # Test notification
    send_pipeline_notification(
        title="Test Notification",
        message="This is a test notification from the BOBJ CI/CD Pipeline.",
        status="info",
        environment="dev",
        build_id="12345",
        pipeline="BOBJ-CI-Pipeline"
    )
