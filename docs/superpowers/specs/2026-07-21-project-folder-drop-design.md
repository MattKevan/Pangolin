# Project Folder Drop Design

## Scope

Allow external folders to be dropped on the Projects view to create and populate a project.

## Interaction

The project grid accepts file URL drops. A dropped folder becomes a top-level project named after the folder. An overlay communicates that a folder can be dropped to create a project.

## Import Structure

The implementation reuses `ProcessingQueueManager.enqueueImport` and `VideoImporter.prepareImportPlan`. The dropped folder becomes the project, its immediate child folders become sections, and discovered video files are queued into the matching project or section. Deeper folders stay flattened into their nearest section, matching the existing project-detail hierarchy.

## Safety and Error Handling

Only external file URLs are accepted. Existing security-scoped URL handling, queued importing, and store error handling remain unchanged. A drop with no importable videos does not create a visible empty project, consistent with the current importer.

## Testing

Add a focused test for the extracted dropped-URL validation policy, then build the macOS app and run the project test target.
