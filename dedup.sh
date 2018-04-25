#!/bin/bash
# By Daniel Fisher, 2018
# Lists and removes duplicate files.
# Shell script version

function printUsage() {
  helpText="$(cat << EOF
Name
	dedup.sh

Synopsis
	dedup.sh [--list] [folder]
	dedup.sh [--delete] [--force] [--deletehl] [folder]
	dedup.sh [--hardlink] [--force] [folder]
        dedup.sh --help


Description
	Search for duplicate files (i.e. files that are truly bitwise-identical,
	ignoring the name) and optionally remove them or replace them with hard
	links to free up storage space. Symbolic links are always ignored.

--help			Display this help information.
--list (Default)	List duplicate files but do not change them.
			Inode numbers are listed so that you can determine if
			the duplication is actually hard linking to the same
			inode. The column order is shasum hash, inode number,
			then path to the file.
--delete                Delete duplicate files (unless they are hard links to
                        the same inode). Exit 3 immediately if a file fails
			to delete for any reason.
	--force		Instead of exiting 3, attempt to proceed even if files
			fail to delete.
	--deletehl	Delete duplicates, including hard links to the same
			inode. This may help with tidiness and confusion issues,
			but it does not really save you storage space.
--hardlink              Delete duplicate files and create hard links to a
                        shared inode. Exit 3 immediately if a file fails to
			delete for any reason.
	--force		See --delete --force.

Exit Status
0       Success (although zero duplicates may have been found if no true
	duplicates exist)
1       Search folder not found
2       Usage issue
3       The program exited becasue a file failed to delete. This is never
	used with --force enabled.

EOF)"
  printf "$helpText\n\n"
  exit $1
}

# Check the arguments provided, if needed
mode="list" # only relevant if no arguments are given.
force="disabled" # this is the default. The user overrides this with --force
deleteHardLinks="disabled"

if [[ $# -ne 0 ]]&&[[ $# -lt 5 ]]; then
  firstArg="$1"
  if [[ "$firstArg" == "--help" ]]; then
    printUsage 0
  elif [[ "$firstArg" == "--list" ]]; then
    mode="list"
  elif [[ "$firstArg" == "--delete" ]]; then
    mode="delete"
  elif [[ "$firstArg" == "--hardlink" ]]; then
    mode="hardlink"
  elif [[ -d "$firstArg" ]]; then
    mode="list"
    searchFolder="$firstArg"
  else
    printUsage 2
  fi
  
  if [[ -n "$searchFolder" ]]&&[[ $# -ge 2 ]]; then
    # If the first argument was the folder, there should be no additional arguments.
    printUsage 2
    
  elif [[ "$mode" == "delete" ]]||[[ "$mode" == "hardlink" ]]; then
    # If using delete or hardlink, the user might be enabling force. This assumes correct
    # usage. A real check of the folder argument will be done below.
    secondArg="$2"
    if [[ "$secondArg" == "--force" ]]; then
      force="enabled"
    elif [[ $secondArg == "--deletehl" ]]; then
      if [[ "$mode" == "delete" ]]; then
        deleteHardLinks="enabled"
      else
        # If they are using dedup.sh --hardlinks --deletehl, then they are silly people. What do they think will happen?
        printUsage 2
      fi
    else
      searchFolder="$secondArg"
    fi
    if [[ -z "$searchFolder" ]]&&[[ $# -ge 3 ]]; then # if we didn't set the search folder yet, there may yet be a --deletehl or a folder.
      thirdArg="$3"
      if [[ $thirdArg == "--deletehl" ]]; then 
        if [[ "$mode" == "delete" ]]; then
          deleteHardLinks="enabled"
        else
          # If they are using dedup.sh --hardlinks --force --deletehl, then they are still silly people.
          printUsage 2
        fi
        if [[ $# == 4 ]]; then
          searchFolder="$4"
        fi
      else
        searchFolder="$thirdArg"
      fi
    fi
    
  elif [[ "$mode" == "list" ]]&&[[ "$#" -gt 2 ]]; then
    # Then the user has done something strange, like try to apply force to list.
    # If that isn't what the user is doing, the user might not realize that an
    # argument needs to be escaped.
    secondArg="$2"
    if [[ "$secondArg" == "--force" ]]; then
      printf "Cannot apply force to list.\nFor usage information, use dedup.sh --help.\n\n"
      exit 2
    else
      printf "list only takes one additional optional argument, a folder to search. Two were provided.\n$secondArg \n$3 \nFor usage information, use dedup.sh --help.\n\n"
      exit 2
    fi
    
  elif [[ $# == 2 ]]; then
    # If there is a second argument, then they are providing the folder.
    # I will check below if a real folder exists at this path.
    searchFolder="$2"
  fi
elif [[ $# -ge 4 ]]; then
  printUsage 2
fi

# ask for a folder if one was not provided.
if [[ -z "$searchFolder" ]]; then
  echo "Drag a folder to search onto Terminal, then press return. Folders will be searched recursively without limit."
  read searchFolder
fi


# Setup logging.
eval mkdir -p "~/Library/Logs/org.danielfisher.dedup"
myLogFile="~/Library/Logs/org.danielfisher.dedup/$( echo `date | sed -e 's/ /_/g' -e 's/:/_/g'`.log )"
echo "Log: $myLogFile" >> "$(eval echo $myLogFile)"
echo "Search Folder: $searchFolder" >> "$(eval echo $myLogFile)"
printf "Mode: $mode\n" >> "$(eval echo $myLogFile)"
printf "Force: $force\n" >> "$(eval echo $myLogFile)"
printf "Delete hard links: $deleteHardLinks\n\n" >> "$(eval echo $myLogFile)"


if [[ ! -d $searchFolder ]]; then # Verify that the folder exists and is a folder.
  printf "Error: Unable to locate a folder with that name.\n"
  printf "Check that the folder exists, is a folder, has that name, and is at that location.\n"
  printf "For usage information, use dedup.sh --help.\n\n"
  exit 1
fi

# Find, within that folder, all normal files that aren't .DS_Store or .localized.
# Also exlcude anything that's in a folder that has a . in the folder name.
# We don't want to deduplicate anything inside of a .app or the like.
#
# This requires a goofy-looking regex, but that's because I don't wnat to just
# Look for any two dots in the path. That would exclude .tar.gz files, for example,
# and it would still deduplicate extensionless files inside of a .app directory.
#
# Then, hash each of those files and find both their hashes and  sort the list by
# hash and inode number, so that duplicates and hard links are both easy to find
#
# This has a few steps. First, we get all the files with hashes and inodes, and we pair them by file.
searchResultPairs=$( find "$searchFolder" -type f \! \( -name ".DS_Store" -or -name ".localized" -or -regex ".*\..*/.*" \) -exec ls -i {} \; -exec shasum {} \; | rev | sort | rev )
# Then, we loop through the results, and extract the relevant data. I'm doing this within a subshell and storing the output in a variable.
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
    # same amount of space as its original. `Du -ch` doesnt't actually mind
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
