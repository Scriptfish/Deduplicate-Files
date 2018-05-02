# Deduplicate-Files
Delete duplicate files and/or unify them with hard links

Summary:

There are two versions of this program. "dedup.sh" is a version intended to be run from the command line. "Duplicate Files.workflow" is an Automator action intended for use on computers running Apple's macOS. It has fewer features, than the shell script version, but it may be more convenient for some macOS users. You'll find the workflow inside the .zip file.

Certain files are intentionally ignored. All .DS_Store files and .localized files are skipped, as are folders that contain "." in the folder name.

Basic Instructions:

1.) I advise users to make backups before using this program.

2.) The program takes one or more folders as an input. The default behavior is to list duplicates in the folders. Other behaviors can be chosen during the pop-ups in the Automator variant or with arguments in the shell script variant.

3.) Shell script users can learn about all of the features with dedup.sh help
