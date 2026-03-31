#!/usr/bin/env python3
"""
ACMOJ Submission Client
Submit git repository URLs to ACMOJ and check submission status
"""

import sys
import os
import requests
import json
import time
import argparse

# Get configuration from environment
ACMOJ_TOKEN = os.environ.get('ACMOJ_TOKEN', '')
ACMOJ_PROBLEM_ID = os.environ.get('ACMOJ_PROBLEM_ID', '2532')
ACMOJ_API_BASE = 'https://acm.sjtu.edu.cn'

def get_git_remote_url():
    """Get the current git repository URL"""
    import subprocess
    try:
        result = subprocess.run(['git', 'remote', 'get-url', 'origin'],
                              capture_output=True, text=True, check=True)
        url = result.stdout.strip()
        # Remove credentials from URL if present
        if '@' in url:
            # Format: https://user:token@github.com/...
            parts = url.split('@')
            if len(parts) == 2:
                protocol_part = parts[0].split('://')
                if len(protocol_part) == 2:
                    url = f"{protocol_part[0]}://{parts[1]}"
        return url
    except subprocess.CalledProcessError as e:
        print(f"Error getting git remote URL: {e}")
        return None

def submit_solution(repo_url=None):
    """Submit a solution to ACMOJ"""
    if not ACMOJ_TOKEN:
        print("Error: ACMOJ_TOKEN not set")
        return None

    if not repo_url:
        repo_url = get_git_remote_url()
        if not repo_url:
            print("Error: Could not determine repository URL")
            return None

    print(f"Submitting repository: {repo_url}")
    print(f"Problem ID: {ACMOJ_PROBLEM_ID}")

    headers = {
        'Authorization': f'Bearer {ACMOJ_TOKEN}',
        'Content-Type': 'application/json'
    }

    data = {
        'problem_id': ACMOJ_PROBLEM_ID,
        'repo_url': repo_url,
        'language': 'verilog'
    }

    try:
        # Try multiple authentication methods
        auth_attempts = [
            ('X-API-Key', f'{ACMOJ_TOKEN}'),
            ('Authorization', f'Bearer {ACMOJ_TOKEN}'),
            ('Authorization', f'Token {ACMOJ_TOKEN}'),
            ('X-Auth-Token', f'{ACMOJ_TOKEN}'),
        ]

        for header_name, header_value in auth_attempts:
            headers_attempt = headers.copy()
            headers_attempt[header_name] = header_value

            response = requests.post(
                f'{ACMOJ_API_BASE}/api/oj/submit',
                headers=headers_attempt,
                json=data,
                timeout=30,
                allow_redirects=False
            )

            # If we don't get a redirect or 401, this might be the right auth method
            if response.status_code not in [302, 401, 403]:
                break

        # If all attempts failed with redirects, try including token in body
        if response.status_code in [302, 401, 403]:
            data_with_token = data.copy()
            data_with_token['token'] = ACMOJ_TOKEN
            response = requests.post(
                f'{ACMOJ_API_BASE}/api/oj/submit',
                headers={'Content-Type': 'application/json'},
                json=data_with_token,
                timeout=30,
                allow_redirects=False
            )

        if response.status_code == 200:
            result = response.json()
            submission_id = result.get('submission_id')
            print(f"✓ Submission successful!")
            print(f"Submission ID: {submission_id}")
            return submission_id
        else:
            print(f"✗ Submission failed: {response.status_code}")
            print(f"Response: {response.text}")
            return None
    except Exception as e:
        print(f"Error submitting: {e}")
        return None

def check_status(submission_id):
    """Check the status of a submission"""
    if not ACMOJ_TOKEN:
        print("Error: ACMOJ_TOKEN not set")
        return None

    headers = {
        'Authorization': f'Bearer {ACMOJ_TOKEN}'
    }

    try:
        response = requests.get(
            f'{ACMOJ_API_BASE}/submission/{submission_id}',
            headers=headers,
            timeout=30
        )

        if response.status_code == 200:
            result = response.json()
            status = result.get('status', 'Unknown')
            score = result.get('score', 'N/A')
            message = result.get('message', '')

            print(f"Submission ID: {submission_id}")
            print(f"Status: {status}")
            print(f"Score: {score}")
            if message:
                print(f"Message: {message}")

            return result
        else:
            print(f"Error checking status: {response.status_code}")
            print(f"Response: {response.text}")
            return None
    except Exception as e:
        print(f"Error checking status: {e}")
        return None

def abort_submission(submission_id):
    """Abort a pending submission"""
    if not ACMOJ_TOKEN:
        print("Error: ACMOJ_TOKEN not set")
        return False

    headers = {
        'Authorization': f'Bearer {ACMOJ_TOKEN}'
    }

    try:
        response = requests.post(
            f'{ACMOJ_API_BASE}/submission/{submission_id}/abort',
            headers=headers,
            timeout=30
        )

        if response.status_code == 200:
            print(f"✓ Submission {submission_id} aborted successfully")
            return True
        else:
            print(f"✗ Failed to abort: {response.status_code}")
            print(f"Response: {response.text}")
            return False
    except Exception as e:
        print(f"Error aborting submission: {e}")
        return False

def wait_for_result(submission_id, timeout=600, poll_interval=10):
    """Wait for submission result"""
    start_time = time.time()

    print(f"Waiting for submission {submission_id} to complete...")

    while time.time() - start_time < timeout:
        result = check_status(submission_id)

        if result:
            status = result.get('status', '')
            if status not in ['Pending', 'Running', 'Judging']:
                print("\n✓ Submission completed!")
                return result

        print(f"Still judging... (elapsed: {int(time.time() - start_time)}s)")
        time.sleep(poll_interval)

    print(f"\n✗ Timeout after {timeout}s")
    print("You can abort this submission with: python acmoj_client.py abort <submission_id>")
    return None

def main():
    parser = argparse.ArgumentParser(description='ACMOJ Submission Client')
    subparsers = parser.add_subparsers(dest='command', help='Commands')

    # Submit command
    submit_parser = subparsers.add_parser('submit', help='Submit a solution')
    submit_parser.add_argument('--repo-url', help='Repository URL (default: current git remote)')
    submit_parser.add_argument('--wait', action='store_true', help='Wait for result')

    # Status command
    status_parser = subparsers.add_parser('status', help='Check submission status')
    status_parser.add_argument('submission_id', help='Submission ID')

    # Abort command
    abort_parser = subparsers.add_parser('abort', help='Abort a pending submission')
    abort_parser.add_argument('submission_id', help='Submission ID')

    args = parser.parse_args()

    if args.command == 'submit':
        submission_id = submit_solution(args.repo_url)
        if submission_id and args.wait:
            wait_for_result(submission_id)
    elif args.command == 'status':
        check_status(args.submission_id)
    elif args.command == 'abort':
        abort_submission(args.submission_id)
    else:
        parser.print_help()

if __name__ == '__main__':
    main()
