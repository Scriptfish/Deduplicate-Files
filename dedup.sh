#!/bin/bash
# By Daniel Fisher, 2018
# Lists and removes duplicate files.
# Shell script version

function printUsage() {
  helpText="$(cat << EOF
Name
	dedup.sh

Synopsis
	dedup.sh [list] [folder(s)]
	dedup.sh [delete] [force] [deletehl] [folder(s)]
	dedup.sh [hardlink] [force] [folder(s)]
        dedup.sh help


Description
	Search for and list duplicate files (i.e. files that are truly bitwise-
	identical, ignoring the name) in any of the provided folders, recursively
	and with no limit to depth. Optionally remove duplicates or replace them
	with hard links to free up storage space. Symbolic links are always ignored.
	
	There is no option for per-folder deduplication. Users who require per-folder
	deduplication, should run the program multiple times, once per folder.

help			Display this help information.
list	 (Default)	List duplicate files but do not change them.
			Inode numbers are listed so that you can determine if
			the duplication is actually hard linking to the same
			inode. The column order is shasum hash, inode number,
			then path to the file.
delete			Delete duplicate files (unless they are hard links to
                        the same inode). Exit 3 immediately if a file fails
			to delete for any reason.
	force		Instead of exiting 3, attempt to proceed even if files
			fail to delete.
	deletehl	Delete duplicates, including hard links to the same
			inode. This may help with tidiness and confusion issues,
			but it does not really save you storage space.
hardlink		Delete duplicate files and create hard links to a
                        shared inode. Exit 3 immediately if a file fails to
			delete for any reason.
	force		See delete force.

Exit Status
0       Success (although zero duplicates may have been found if no true
	duplicates exist)
1       Search folder not found
2       Usage issue
3       The program exited because a file failed to delete. This never
	is used with force enabled.
4	An error occurred while listing files to compare.

EOF)"
  printf "$helpText\n\n"
  exit $1
}

# Set up logging
eval mkdir -p "~/Library/Logs/org.danielfisher.dedup"
myLogFile="~/Library/Logs/org.danielfisher.dedup/$( echo `date | sed -e 's/ /_/g' -e 's/:/_/g'`.log )"
printf "Log: $myLogFile\n" >> "$(eval echo $myLogFile)"

# Check any provided arguments provided
for arg in "$@"
do
  if [[ -z "$mode" ]] && ( [[ "$arg" == "help" ]]||[[ "$arg" == "list" ]]||[[ "$arg" == "delete" ]]||[[ "$arg" == "hardlink" ]] ); then
    if [[ -z "$mode" ]]; then
      mode="$arg"
      if [[ "$mode" == "help" ]]; then
        printUsage 0
      fi
    else
      # then the user is providing multiple modes, which is unexpected. Error out.
      printf "Error: Multiple modes have been provided, $mode and $arg.\n" | tee -a "$(eval echo $myLogFile)"
      printf "For usage information, use dedup.sh help.\n\n" | tee -a "$(eval echo $myLogFile)"
      exit 2
    fi
  elif ( [[ "$mode" == "delete" ]]||[[ "$mode" == "hardlink" ]] ) && ( [[ "$arg" == "force" ]]||[[ "$arg" == "deletehl" ]]); then
    # check for the force or deletehl arguments
    if [[ "$mode" == "hardlink" ]]&&[[ "$arg" == "deletehl" ]]; then
      printf "Error: Deletehl is not compatible with hardlink mode.\n" | tee -a "$(eval echo $myLogFile)"
      printf "For usage information, use dedup.sh help.\n\n" | tee -a "$(eval echo $myLogFile)"
      exit 2
    else
      # It doesn't really matter if they set them multiple times. It also does not matter which order they set them.
      if [[ "$arg" == "force" ]]; then
        force="enabled"
      else
        deleteHardLinks="enabled"
      fi
    fi
  elif [[ -d "$arg" ]]; then
    if [[ -z "$mode" ]]; then
      mode="list"
    fi
    searchFolders=( "$searchFolders \"$arg\"" )
  elif [[ "$arg" == "force" ]]||[[ "$arg" == "deletehl" ]]; then
    # then the user is setting mode with list, or without first declaring the mode to be delete or hardlink.
    printf "Error: Cannot use $arg without first choosing delete or hardlink mode.\n" | tee -a "$(eval echo $myLogFile)"
    printf "For usage information, use dedup.sh help.\n\n" | tee -a "$(eval echo $myLogFile)"
    exit 2
  else
    printf "Error: Unable to discern user intent with argument \""$arg"\".\n" | tee -a "$(eval echo $myLogFile)"
    printf "For usage information, use dedup.sh help.\n\n" | tee -a "$(eval echo $myLogFile)"
    exit 2
  fi
done

# explicitly set any unset modes or arguments to modes
if [[ -z "$mode" ]]; then
  mode="list"
fi
if [[ -z "$force" ]]; then
  force="disabled"
fi
if [[ -z "$deleteHardLinks" ]]; then
  deleteHardLinks="disabled"
fi

# ask for a (single) folder if one was not provided.
if [[ -z "$searchFolders" ]]; then
  echo "Drag a folder to search onto Terminal, then press return. Folders will be searched recursively without limit."
  read searchFolders
  if [[ ! -d $searchFolders ]]; then # Verify that the folder exists and is a folder.
    printf "Error: Unable to locate a folder with that name.\n" | tee -a "$(eval echo $myLogFile)"
    printf "Check that the folder exists, is a folder, has that name, and is at that location.\n" | tee -a "$(eval echo $myLogFile)"
    printf "For usage information, use dedup.sh help.\n\n" | tee -a "$(eval echo $myLogFile)"
    exit 1
  else
    searchFolders="\"$searchFolders\"" # add quotes around the folder.
  fi
fi

# Log arguments 
printf "Search Folders: $searchFolders\n" >> "$(eval echo $myLogFile)"
printf "Mode: $mode\n" >> "$(eval echo $myLogFile)"
printf "Force: $force\n" >> "$(eval echo $myLogFile)"
printf "Delete hard links: $deleteHardLinks\n\n" >> "$(eval echo $myLogFile)"


# Find, within that folder, all normal files that aren't .DS_Store or .localized.
# Also exclude anything that's in a folder that has a . in the folder name.
# We don't want to deduplicate anything inside of a .app or the like.
#
# This requires a goofy-looking regex, but that's because I don't want to just
# Look for any two dots in the path. That would exclude .tar.gz files, for example,
# and it would still deduplicate extension-less files inside of a .app directory.
#
# Then, hash each of those files and find both their hashes and  sort the list by
# hash and inode number, so that duplicates and hard links are both easy to find.
# 
# Unfortunately, all of this needs to be run through the shell builtin 'eval' because of the
# way multiple files are handles. That means even more backslashes than normal, throughout the find command.
#
# This has a few steps. First, we get all the files with hashes and inodes, and we pair them by file.
searchResultPairs=$( eval find "$searchFolders" -type f \\\! \\\( -name \".DS_Store\" -or -name \".localized\" -or -regex \"\.\*\\\.\.\*\/\.\*\" \\\) -exec ls -i {} \\\; -exec shasum {} \\\; | rev | sort | uniq | rev )
# I recognize that this looks dizzying. The body of this find command will ultimately become -type f ! ( -name .DS_Store -or -name .localized -or -regex .*\..*/.* ) -exec ls -i {} ; -exec shasum {} ;
# | sort | uniq: This is a safeguard against the user accidentally specifying the same folder twice or one folder that contains another folder. I'm trying not to delete everyone's data if they make a mistake.
# | rev | sort | ... | rev: I'm trying to consolidate shasum hashes and inode numbers. This sorts from the end of the line instead of the beginning.

if [[ "$?" -ne 0 ]]; then
  # Then something went wrong with the find command.
  echo "Echo: An unexpected error occurred while finding files. Exiting." | tee -a "$(eval echo $myLogFile)"
  exit 4
fi

# Then, we loop through the results, and extract the relevant data. I'm doing this within a sub-shell and storing the output in a variable.
searchResults="$( for ((ix=1; ix<$(echo "$searchResultPairs" | wc -l); ix+=2)); do
  echo "$( echo "$searchResultPairs" | head -n $ix | tail -n 1 | awk '{print $1}' ) $( echo "$searchResultPairs" | head -n $(( $ix + 1 )) | tail -n 1 )"
done )"

# Create a regular expression of each hash that has >1 occurrence.
regexOfHashes="($( echo "$searchResults" | awk '{print $1}' | sort | uniq -d | tr '\n' '|' | rev | sed 's/|//' | rev ))"
if [[ "$regexOfHashes" == "()" ]]; then
  # if there are no matched hashes, we can exit.
  echo "No duplicates found." | tee -a "$(eval echo $myLogFile)"
  exit 0
fi

# Look for duplicate files by grepping the search results for that regex of
# hashes with >1 occurrence
foundDuplicates="$(echo "$searchResults" | egrep "$regexOfHashes")"

printf "Found Duplicates:\n$foundDuplicates\n\n" >> "$(eval echo $myLogFile)"
if [[ "$mode" == "list" ]]; then
  echo "$foundDuplicates"
  exit 0
fi

# Convert the regular expression of the hashes from before into an array, so that
# we can loop through it in a moment.
arrayOfHashes=($( echo "$regexOfHashes" | tr -d "()" | sed 's/|/ /g' ))


totalFilesDeleted=0

# Now, loop through each hash with duplicates.
for eachMatchedHash in "${arrayOfHashes[@]}"
do
  # Instances is the number of instances of that hash
  instances=$( echo "$foundDuplicates" | egrep "$eachMatchedHash" | wc -l )
  
  inodeOfOriginal=$( echo "$foundDuplicates" | egrep "$eachMatchedHash" | head -n 1 | awk '{print $2}' )
  pathOfOriginal="$( echo "\"$( echo "$foundDuplicates" | egrep "$eachMatchedHash" | head -n 1 | awk '{$1=""; $2=""; print $0}' | tail -n 1 | sed 's/  //')\"" )"
  
  # toDelete is the array of files to delete (including the inode numbers). It does
  # not include the original file.
  toDelete=$( echo "$foundDuplicates" | egrep "$eachMatchedHash" | tail -n $(( $instances-1 )) | awk '{for (ix=2; ix<NF; ix++) printf $ix " "; print $NF}' )
  
  for ((ix=1; ix<$instances; ix++)); do
    # Note that ix begins at 1, not 0. We don't want to delete every instance of 
    # the duplicated file because then we wouldn't have any copies left.
    # We need to keep one copy, and we choose to keep the first.
    
    inodeOfThisInstance=$( echo "$toDelete" | head -n $ix | tail -n 1 | awk '{print $1}' )
    pathOfThisInstance="$( echo "\"$( echo "$toDelete" | head -n $ix | tail -n 1 |awk '{$1=""; print $0}' | sed 's/ //')\"" )"
    
    # I'm about to do something slightly confusing over here, but not too bad.
    #
    # I wanted to delete all of the duplicate files during this loop, because it
    # made the task of keeping track of the originals for each much simpler,
    # and I need to track originals if I'm going to replace them with hard links.
    #
    # On the other hand, I also want to give the user a grand total of saved space,
    # and it's hard to determine how much space a file took up after deleting it.
    #
    # The solution is that each duplicate is a duplicate, so it takes up the
    # same amount of space as its original. `Du -ch` doesn't actually mind
    # if you provide the same file multiple times as arguments, and it computes
    # the total amount of disk space that they would have taken up if they were
    # actually separate files.
    
    if [[ "$deleteHardLinks" == "enabled" ]]||[[ "$inodeOfOriginal" != "$inodeOfThisInstance" ]]; then
      echo "Deleting duplicate: $pathOfThisInstance" >> "$(eval echo $myLogFile)"
      eval "rm -f $( echo "$pathOfThisInstance" )"
      if [[ "$?" != 0 ]]; then
        echo "Failed to delete $pathOfThisInstance" >> "$(eval echo $myLogFile)"
        # If anything failed to delete, exit with an error status, unless force is enabled.
        if [[ "$force" == "enabled" ]]; then
          continue
        else
          exit 3
        fi
      else
        totalFilesDeleted=$(( $totalFilesDeleted + 1 ))
        if [[ "$inodeOfOriginal" != "$inodeOfThisInstance" ]]; then # do not count storage space for deleted hard links to the same inode, as no space will actually be freed up.
          originalsOfAllDeleted="$originalsOfAllDeleted $pathOfOriginal"
        fi
        if [[ "$mode" == "hardlink" ]]; then
          echo "Hard linking $pathOfOriginal to $pathOfThisInstance" >> "$(eval echo $myLogFile)"
          eval "ln $( echo "$pathOfOriginal" "$pathOfThisInstance" )"
        fi
      fi
    else
      printf "Not deleting: $pathOfThisInstance\n  It shares inode number $inodeOfOriginal with $pathOfOriginal\n" >> "$(eval echo $myLogFile)"
    fi
  done
done


# Tell the user how much space will be saved.
if [[ $totalFilesDeleted == 0 ]]; then
  # if there are no matched hashes, we can exit.
  if [[ "$deleteHardLinks" == "enabled" ]]; then
    printf "\nNo duplicates found.\n" | tee -a "$(eval echo $myLogFile)"
  else
    printf "\nNo (non-hard-link) duplicates found.\n" | tee -a "$(eval echo $myLogFile)"
  fi
else
  if [[ -z "$originalsOfAllDeleted" ]]; then
    # Then we deleted files, but all of them must have been shared inode numbers.
    printf "\nDeleted $totalFilesDeleted files.\n" | tee -a "$(eval echo $myLogFile)"
  else
    printf "\nDeleted $totalFilesDeleted files to save approximately $(echo "$( eval "du -ch $originalsOfAllDeleted")" | tail -n 1 | awk '{print $1}') of storage space.\n" | tee -a "$(eval echo $myLogFile)"
  fi
fi

exit 0
