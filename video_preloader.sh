#!/bin/bash
# #####################################
# Script:      Video Preloader v1.4
# Description: Preloads the recent video files of a specific path into the RAM to bypass HDD spinup latency
# Author:      Marc Gutt
# Source:      https://forums.unraid.net/topic/97982-video-preloader-avoids-hdd-spinup-latency-when-starting-a-movie-or-episode-through-plex-jellyfin-or-emby/#comment-904118
# ######### Settings ##################

video_paths=(
  "/mnt/user/Movie"
  "/mnt/user/TV"
)

# the size of a video files must be at least 2GB (to exclude bonus content)
video_min_size="2000MB" 

# we preload 60MB of the beginning of the video file into the RAM (raise this value if your video buffers after ~5 seconds)
preload_head_size="60MB"

# we preload 1MB of the end of the video file
preload_tail_size="1MB" 

# if a preload is faster than 0.150 seconds than the video is already preloaded to the RAM
preload_threshold="0.150"

# preload only video files with specific extensions https://support.plex.tv/articles/203824396-what-media-formats-are-supported/
video_ext='avi|mkv|mov|mp4|mpeg'

# preload only subtitle files with specific extensions # https://support.plex.tv/articles/200471133-adding-local-subtitles-to-your-media/#toc-1
sub_ext='srt|smi|ssa|ass|vtt'

# we use 50% of our free RAM for preloading (it will be still free, check https://www.linuxatemyram.com/)
free_ram_usage_percent=50

# set this to "1" to remove all preloads (this is only usefull if you want to force reading from Disk)
preclean_cache=0

# notify if the execution was sucessful (errors produce notifications by default)
notification=1

# #####################################
# 
# ######### Script ####################

# timestamping logs
exec &> >(stdbuf -o0 sed 's/%/%%/g' | xargs -d '\n' -I {} date '+%F %T {}')

# make script race condition safe
if [[ -d "/tmp/${0///}" ]] || ! mkdir "/tmp/${0///}"; then exit 1; fi; trap 'rmdir "/tmp/${0///}"' EXIT;

# check user settings
video_min_size="${video_min_size//[!0-9.]/}" # float filtering https://stackoverflow.com/a/19724571/318765
video_min_size=$(awk "BEGIN { print $video_min_size*1000000}") # convert MB to Bytes
preload_head_size="${preload_head_size//[!0-9.]/}"
preload_head_size=$(awk "BEGIN { print $preload_head_size*1000000}")
preload_tail_size="${preload_tail_size//[!0-9.]/}"
preload_tail_size=$(awk "BEGIN { print $preload_tail_size*1000000}")

# check if paths are used in docker containers
if docker info > /dev/null 2>&1; then
  # get docker mounts of all running containers
  # shellcheck disable=SC2016
  docker_mounts=$(docker ps -q | xargs docker container inspect -f '{{$id := .Id}}{{range .Mounts}}{{if .Source}}{{printf $id}}:{{.Source}}{{println}}{{end}}{{end}}' | grep -v -e "^$")
  for path in "${video_paths[@]}"; do
    if [[ $docker_mounts != *"$path"* ]]; then
      /usr/local/emhttp/webGui/scripts/notify -i alert -s "Plex Preloader failed!" -d "$path is not used by a docker container!"
      exit 1
    fi
  done
fi

# clean the read cache
if [ "$preclean_cache" = "1" ]; then
  sync; echo 1 > /proc/sys/vm/drop_caches
fi

# preload calculation
preloaded=0
skipped=0
preload_total_size=$((preload_head_size + preload_tail_size))
free_ram=$(free -b | awk '/^Mem:/{print $7}')
free_ram=$((free_ram * free_ram_usage_percent / 100))
echo "Available RAM: $(numfmt --to si $free_ram)"
preload_amount=$((free_ram / preload_total_size))
preload_size=$(( preload_head_size + preload_tail_size ))
echo "Amount of videos that can be preloaded: $preload_amount (each video occupies $(numfmt --to si $preload_size))"

# find all video files
while IFS= read -r -d '' file; do
  video_files+=("$file")
done < <(find "${video_paths[@]}" -not -path '*/.*' -size +"$video_min_size"c -regextype posix-extended -regex ".*\.($video_ext)" -printf "%T@ %p\0")

# no video files found
if [[ ${#video_files[@]} -eq 0 ]]; then
  echo "No $video_ext files found in ${video_paths[*]}!"
else

  # sort all video files
  while IFS= read -r -d '' file; do
    video_files_sorted+=("$file")
  done < <(printf '%s\0' "${video_files[@]}" | sort -znr)

  # preload video files into RAM
  for i in "${!video_files_sorted[@]}"; do
    # stop if we reached our preload limit
    if [[ $i -ge $preload_amount ]]; then
      break;
    fi
    # remove modification time
    file=$(echo "${video_files_sorted[$i]}" | cut -f2- -d" ")
    TIMEFORMAT=%R
    seconds=$( { time head -c "$preload_head_size" "$file" >/dev/null; } 2>&1 )
    if awk 'BEGIN {exit !('"$seconds"' >= '"$preload_threshold"')}'; then
      preloaded=$((preloaded + 1))
      echo "Preloaded $file in $seconds seconds"
    else
      echo "Skipped $file as loading needed only $seconds"
      skipped=$((skipped + 1))
    fi
    tail -c "$preload_tail_size" "$file" > /dev/null
    video_path=$(dirname "$file")
    # fetch subtitle files
    find "$video_path" -not -path '*/.*' -regextype posix-extended -regex ".*\.($sub_ext)" -print0 | 
      while IFS= read -r -d '' file; do 
        echo "Preloaded $file"
        cat "$file" >/dev/null
      done
  done

fi

# notification
if [[ $preloaded -eq 0 ]] && [[ $skipped -eq 0 ]]; then
  /usr/local/emhttp/webGui/scripts/notify -i alert -s "Plex Preloader failed!" -d "No video file has been preloaded (wrong path?)!"
elif [ "$notification" == "1" ]; then
  /usr/local/emhttp/webGui/scripts/notify -i normal -s "Plex Preloader has finished" -d "$preloaded preloaded (from Disk) / $skipped skipped (already in RAM)"
fi