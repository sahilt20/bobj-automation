"""
SAP BusinessObjects LCMBIAR Validator

This module provides validation functionality for LCMBIAR packages
used in SAP BusinessObjects content transport.
"""

import argparse
import json
import os
import sys
import zipfile
from pathlib import Path
from typing import Dict, List, Optional
from dataclasses import dataclass, asdict
import xml.etree.ElementTree as ET


@dataclass
class ValidationResult:
    """Represents the result of a validation check."""
    valid: bool
    object_count: int
    warnings: List[str]
    errors: List[str]
    objects: List[Dict]
    manifest_found: bool
    dependencies_valid: bool


def validate_structure(input_path: str) -> ValidationResult:
    """
    Validate the structure of an LCMBIAR package.
    
    Args:
        input_path: Path to LCMBIAR file or extracted directory
        
    Returns:
        ValidationResult with validation details
    """
    result = ValidationResult(
        valid=True,
        object_count=0,
        warnings=[],
        errors=[],
        objects=[],
        manifest_found=False,
        dependencies_valid=True
    )
    
    path = Path(input_path)
    
    if not path.exists():
        result.valid = False
        result.errors.append(f"Path does not exist: {input_path}")
        return result
    
    if path.is_file():
        # Handle .lcmbiar file (usually a ZIP archive)
        if path.suffix.lower() == '.lcmbiar' or path.suffix.lower() == '.zip':
            result = validate_lcmbiar_archive(path, result)
        else:
            # Single file
            result.object_count = 1
            result.objects.append({
                'name': path.name,
                'size': path.stat().st_size,
                'type': path.suffix
            })
    else:
        # Directory
        result = validate_directory(path, result)
    
    return result


def validate_lcmbiar_archive(path: Path, result: ValidationResult) -> ValidationResult:
    """Validate an LCMBIAR archive file."""
    try:
        with zipfile.ZipFile(path, 'r') as zf:
            file_list = zf.namelist()
            result.object_count = len(file_list)
            
            # Check for manifest
            manifest_files = [f for f in file_list if 'manifest' in f.lower() or f.endswith('.xml')]
            if manifest_files:
                result.manifest_found = True
            else:
                result.warnings.append("No manifest file found in archive")
            
            # Catalog objects
            for filename in file_list[:50]:  # Limit to first 50 for performance
                info = zf.getinfo(filename)
                result.objects.append({
                    'name': filename,
                    'size': info.file_size,
                    'compressed_size': info.compress_size,
                    'type': Path(filename).suffix
                })
            
            if len(file_list) > 50:
                result.warnings.append(f"Only showing first 50 of {len(file_list)} objects")
                
    except zipfile.BadZipFile:
        result.errors.append("Invalid or corrupted LCMBIAR archive")
        result.valid = False
    except Exception as e:
        result.errors.append(f"Error reading archive: {str(e)}")
        result.valid = False
    
    return result


def validate_directory(path: Path, result: ValidationResult) -> ValidationResult:
    """Validate an extracted LCMBIAR directory."""
    all_files = list(path.rglob('*'))
    files = [f for f in all_files if f.is_file()]
    
    result.object_count = len(files)
    
    if result.object_count == 0:
        result.errors.append("Directory contains no files")
        result.valid = False
        return result
    
    # Check for manifest
    manifest_files = [f for f in files if 'manifest' in f.name.lower() or f.suffix == '.xml']
    if manifest_files:
        result.manifest_found = True
        # Try to parse manifest
        for mf in manifest_files:
            try:
                tree = ET.parse(mf)
                root = tree.getroot()
                result.objects.append({
                    'name': mf.name,
                    'type': 'manifest',
                    'root_tag': root.tag
                })
            except ET.ParseError:
                result.warnings.append(f"Could not parse manifest: {mf.name}")
    else:
        result.warnings.append("No manifest file found")
    
    # Catalog files
    for f in files[:50]:
        try:
            result.objects.append({
                'name': f.name,
                'size': f.stat().st_size,
                'type': f.suffix,
                'path': str(f.relative_to(path))
            })
        except Exception:
            pass
    
    if len(files) > 50:
        result.warnings.append(f"Only showing first 50 of {len(files)} objects")
    
    return result


def check_dependencies(input_path: str) -> Dict:
    """
    Check for missing dependencies in the LCMBIAR package.
    
    Args:
        input_path: Path to LCMBIAR package
        
    Returns:
        Dictionary with dependency check results
    """
    result = {
        'checked': True,
        'missing_dependencies': [],
        'warnings': []
    }
    
    path = Path(input_path)
    
    # For now, perform basic dependency checks
    # In a real implementation, this would parse BOBJ metadata
    
    if path.is_dir():
        # Look for universe files that might reference connections
        universe_files = list(path.rglob('*.unx')) + list(path.rglob('*.unv'))
        if universe_files:
            result['warnings'].append(
                f"Found {len(universe_files)} universe file(s) - verify connections exist in target"
            )
    
    return result


def check_manifest(input_path: str) -> Dict:
    """
    Validate the manifest file in the LCMBIAR package.
    
    Args:
        input_path: Path to LCMBIAR package
        
    Returns:
        Dictionary with manifest validation results
    """
    result = {
        'found': False,
        'valid': False,
        'entries': 0,
        'errors': []
    }
    
    path = Path(input_path)
    
    manifest_paths = []
    if path.is_dir():
        manifest_paths = list(path.rglob('*manifest*.xml')) + list(path.rglob('manifest.json'))
    
    if not manifest_paths:
        result['errors'].append("No manifest file found")
        return result
    
    result['found'] = True
    
    for mf in manifest_paths:
        try:
            if mf.suffix == '.xml':
                tree = ET.parse(mf)
                root = tree.getroot()
                result['entries'] = len(list(root.iter()))
                result['valid'] = True
            elif mf.suffix == '.json':
                with open(mf, 'r') as f:
                    data = json.load(f)
                result['entries'] = len(data) if isinstance(data, list) else 1
                result['valid'] = True
        except Exception as e:
            result['errors'].append(f"Error parsing {mf.name}: {str(e)}")
    
    return result


def main():
    """Main entry point for CLI usage."""
    parser = argparse.ArgumentParser(description='LCMBIAR Package Validator')
    parser.add_argument('--input', '-i', required=True, help='Path to LCMBIAR file or directory')
    parser.add_argument('--check-structure', action='store_true', help='Validate package structure')
    parser.add_argument('--check-dependencies', action='store_true', help='Check for missing dependencies')
    parser.add_argument('--check-manifest', action='store_true', help='Validate manifest file')
    parser.add_argument('--fail-on-missing', action='store_true', help='Fail if dependencies are missing')
    parser.add_argument('--output', '-o', help='Output path for validation report (JSON)')
    
    args = parser.parse_args()
    
    print(f"LCMBIAR Validator - Validating: {args.input}")
    print("=" * 50)
    
    all_valid = True
    report = {}
    
    # Structure validation
    if args.check_structure:
        print("\n[Checking Structure...]")
        result = validate_structure(args.input)
        report['structure'] = asdict(result)
        
        print(f"  Valid: {result.valid}")
        print(f"  Objects: {result.object_count}")
        print(f"  Manifest Found: {result.manifest_found}")
        
        for warn in result.warnings:
            print(f"  ⚠ Warning: {warn}")
        for err in result.errors:
            print(f"  ✗ Error: {err}")
        
        if not result.valid:
            all_valid = False
    
    # Dependency check
    if args.check_dependencies:
        print("\n[Checking Dependencies...]")
        dep_result = check_dependencies(args.input)
        report['dependencies'] = dep_result
        
        if dep_result['missing_dependencies']:
            print(f"  ✗ Missing: {', '.join(dep_result['missing_dependencies'])}")
            if args.fail_on_missing:
                all_valid = False
        else:
            print("  ✓ No missing dependencies detected")
        
        for warn in dep_result['warnings']:
            print(f"  ⚠ {warn}")
    
    # Manifest validation
    if args.check_manifest:
        print("\n[Checking Manifest...]")
        manifest_result = check_manifest(args.input)
        report['manifest'] = manifest_result
        
        print(f"  Found: {manifest_result['found']}")
        print(f"  Valid: {manifest_result['valid']}")
        print(f"  Entries: {manifest_result['entries']}")
        
        for err in manifest_result['errors']:
            print(f"  ✗ Error: {err}")
    
    # Save report
    if args.output:
        output_path = Path(args.output)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        with open(output_path, 'w') as f:
            json.dump(report, f, indent=2)
        print(f"\nReport saved to: {args.output}")
    
    # Summary
    print("\n" + "=" * 50)
    if all_valid:
        print("✓ Validation PASSED")
        sys.exit(0)
    else:
        print("✗ Validation FAILED")
        sys.exit(1)


if __name__ == '__main__':
    main()
