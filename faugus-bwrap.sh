#!/usr/bin/env bash
script_name="${0##*/}"

# Dynamically assign path values to required binaries
# instead of hardcoding them
declare -Ag binary_list
for i in umu-run bwrap faugus-launcher switcherooctl vulkaninfo; do
	binary_list[$i]=$(command -v $i)
done

# Store user and group id
uid=$(id -u)
gid=$(id -g)

# Warn when running as root
if [[ $uid -eq 0 || $gid -eq 0 ]]; then
	echo "WARNING: Running as root will fully expose device files!"
	echo -ne "Continue? (y/n)\n> "
	read -r i
	if [[ $i != y ]]; then
		exit
	fi
fi

# Define common directory paths for convenience
home_dir="$HOME/.bwrap/Faugus"
conf_dir="$HOME/.config"
cache_dir="$HOME/.cache"
local_dir="$HOME/.local/share"
local_umu="$home_dir/.local/share/faugus-launcher/umu-run"
sandbox_umu="$local_dir/faugus-launcher/umu-run"
sandbox_conf="$home_dir/.config"
sandbox_local="$home_dir/.local/share"

# Extra shell options for proper functionality of regexes/expansions
shopt -s nullglob extglob

# Reset important variables before start
unset bwrap_args user_args pre_launch gpu_select \
full_isolation verbose_args net_access create_dirs

help_msg() {
echo "A script that isolates Faugus and your games from the rest of the system using Bubblewrap

Options:
  -o = Enable network access (online)
  -x = Force use X11
  -w = Force use Wayland
  -i = Use integrated graphics
  -f = Run games in full isolation
  -c = Create user-defined directories that don't exist yet
  -v = Print launch arguments (verbose)
  -h = Show this help message

Note:
In normal mode, the script will use the normal Faugus and Umu dirs in $conf_dir and $local_dir.

In isolation mode (-f), these folders will be separated from the normal dirs, and instead located in $sandbox_conf and $sandbox_local.

Additionally, separated game folders are also mounted in isolation mode.
(Search for \"define_user_dirs\" inside the script)

Usage:
$script_name <options>"
exit
}

find_gpus() {
# Check which gpu finder is available
if [[ -n "${binary_list[switcherooctl]}" ]]; then
	tool_type=switcherooctl
	tool_cmd=(${binary_list[switcherooctl]} list)
elif [[ -n "${binary_list[vulkaninfo]}" ]]; then
	tool_type=vulkaninfo
	tool_cmd=(${binary_list[vulkaninfo]} --summary)
fi

# Arrays to store gpu names and id numbers
declare -Ag gpu_ids
declare -Ag gpu_names

# Clear values before scanning for gpus
unset gpu_type gpu_name gpu_id has_nvidia

# Initial values to assign to found gpus
igpu_counter=0
dgpu_counter=0

while IFS= read -r line; do
	# Find gpu ID number (switcherooctl || vulkaninfo)
	if [[ "$line" =~ Device:[[:space:]]*([0-9]+) || "$line" =~ GPU([0-9]+): ]]; then
		gpu_id="${BASH_REMATCH[1]}"
	fi

	# Get the gpu type (switcherooctl || vulkaninfo)
	if [[ "$line" =~ Discrete:[[:space:]]*(yes|no) || "$line" =~ (INTEGRATED|DISCRETE)_GPU ]]; then
		if [[ ${BASH_REMATCH[1]} =~ (^yes$|DISCRETE) ]]; then
			gpu_type=d
		else
			gpu_type=i
		fi
	fi

	# Get the gpu name (switcherooctl || vulkaninfo)
	if [[ "$line" =~ Name:[[:space:]]*(.+) || "$line" =~ deviceName[[:space:]]*=[[:space:]]*(.*) ]]; then
		gpu_name="${BASH_REMATCH[1]}"
		if [[ "$gpu_name" =~ NVIDIA ]]; then
			has_nvidia=1
		fi
	fi

	# Add gathered values to the gpu lists
	if [[ -n $gpu_id && -n $gpu_type && -n $gpu_name ]]; then
		if [[ $gpu_type == i ]]; then
			(( igpu_counter++ ))
			gpu_ids["i$igpu_counter"]=$gpu_id
			gpu_names["i$igpu_counter"]="$gpu_name"
		elif [[ $gpu_type == d ]]; then
			(( dgpu_counter++ ))
			gpu_ids["d$dgpu_counter"]=$gpu_id
			gpu_names["d$dgpu_counter"]="$gpu_name"
		fi
		unset gpu_type gpu_name gpu_id
	fi
done < <("${tool_cmd[@]}" 2> /dev/null)
}

select_gpu() {
# Find available gpus before running the picker
find_gpus

# Pick first gpu by default
selection=1

# Silently switch to igpu if no dgpus are found
if [[ $dgpu_counter -eq 0 || $1 == integrated ]]; then
	gpu_type=i
	gpu_count=$igpu_counter
elif [[ $1 == discrete ]]; then
	gpu_type=d
	gpu_count=$dgpu_counter
fi

# Ask user to pick a gpu if >1 are found
if [[ $gpu_count -gt 1 ]]; then
	echo "Multiple gpus detected! Select one:"
	for (( i=1; i<=gpu_count; i++ )); do
		echo "$i) ${gpu_names[$gpu_type$i]}"
	done
	echo -n "> "
	read -r selection
fi

# Ensure user doesn't pick nonexistent gpu
if [[ -z "${gpu_names[$gpu_type$selection]}" ]]; then
	echo "Invalid gpu selection!"
	exit
fi

# Use the selected gpu for rendering games
if [[ $tool_type == switcherooctl ]]; then
	pre_launch+=(${binary_list[switcherooctl]} launch --gpu=${gpu_ids[$gpu_type$selection]})
elif [[ $tool_type == vulkaninfo && $has_nvidia -eq 1 ]]; then
	bwrap_args+=(--setenv __NV_PRIME_RENDER_OFFLOAD)
	if [[ $gpu_type == i ]]; then
		bwrap_args+=(0)
	else
		bwrap_args+=(1)
	fi
fi
bwrap_args+=(--setenv DRI_PRIME "${gpu_ids[$gpu_type$selection]}!")
}

apply_required_args() {
# Apply initial args
bwrap_args+=(
--die-with-parent

# Unshare unnecessary namespaces
--unshare-{user,ipc,pid,uts,cgroup}

# Map user and group id into sandbox
--uid $uid
--gid $gid

# Create basic sandbox structure
--dev /dev
--proc /proc

# Create writable /tmp
--tmpfs /tmp

# Isolate home dir to another folder
--bind $home_dir $HOME

# Query and set current gtk theme
--setenv GTK_THEME $(gsettings get org.gnome.desktop.interface gtk-theme | tr -d "'")
)
}

define_required_dirs() {
# List of directories to mount
required_mounts=(
# Bind required devices for gaming
/dev/{{,u}input,shm,ntsync,snd,dri,hidraw*,nvidia*}

# Bind required stuff for umu to function
/etc/{fonts,resolv.conf,passwd,group,machine-id,ld.so.cache,pki}

# Bind required filesystem directories
/{usr/!(local|sbin)\
,lib{,64},bin,sys/{dev{,ices},class,bus},run/udev}

# Bind required user xdg sockets
$XDG_RUNTIME_DIR/\
{bus,pipewire-+([0-9]),pulse/native,$WAYLAND_DISPLAY}

# Include faugus and umu binaries outside /usr/bin
{/usr/local/bin,$HOME/.local/bin}/{faugus-launcher,umu-run}

# Required bind for mangohud functionality
$conf_dir/MangoHud/MangoHud.conf

# Required bind for proton functionality
$local_dir/Steam/compatibilitytools.d

# Theming support (gtk/qt+kde)
$conf_dir/{gtk{rc{,-2.0},-{2..4}.0},kdeglobals}
)
}

define_isolation_dirs() {
# Additional mounts for complete system integration
integrated_mounts=(
# Bind additional xdg sockets
$XDG_RUNTIME_DIR/at-spi/bus_+([0-9])

# Share required dirs for faugus+umu integration
$conf_dir/faugus-launcher
$local_dir/{umu,faugus-launcher}
)

# Required mounts for isolation mode
isolated_mounts=(
# Mount steamrt dir as readonly with overlayfs
--overlay-src $local_dir/umu
--tmp-overlay $local_dir/umu
)
}

# User-defined list of game directories
# Add/remove/modify them as needed
# Format: source_dir destination_dir
define_user_dirs() {

# Normal mounts are for games you want visible to
# everything in your home folder
normal_user_mounts=(
$HOME/{Games,Faugus}{,}
)

# Isolated mounts are for games you want isolated
# from the rest of your home folder
isolated_user_mounts=(
$HOME/Faugus{/.isolated,}
$HOME/Games{/.isolated,}
)

# Shared mounts are for games you want accessible on both modes
# e.g., removable drives
shared_user_mounts=(
{,/run}/media/$USER{,}
)
}

create_user_dirs() {
full_dir_list=(
"${normal_user_mounts[@]}"
"${isolated_user_mounts[@]}"
"${shared_user_mounts[@]}"
)

# Create dirs if they don't exist yet
for (( i=0; i<${#full_dir_list[@]}; i+=2 )); do
	current_dir="${full_dir_list[i]}"
	if [[ "$current_dir" =~ ^((/(run/)?media/[^/]+/[^/]+)) ]]; then
		echo "${BASH_REMATCH[1]}"
		if [[ -d "${BASH_REMATCH[1]}" ]]; then
			mkdir -p "$current_dir"
		fi
	else
		mkdir -p "$current_dir"
	fi
done 2> /dev/null
}

apply_defined_dirs() {
# Apply required args
apply_required_args

# Load defined dirs
define_required_dirs
define_isolation_dirs
define_user_dirs

# Add required isolated mounts
if [[ $full_isolation -eq 1 ]]; then
	local_regex="$local_dir/!([Ss]team*)"
	required_mounts+=("${isolated_mounts[@]}")
else
	local_regex="$local_dir/*"
	required_mounts+=("${integrated_mounts[@]}")
fi

conf_regex="$conf_dir/!(MangoHud*|gtk*|kde*|qt*)"

# Add required mounts to bwrap_args
for i in "${required_mounts[@]}"; do
	case "$i" in
		/dev/*) bwrap_args+=(--dev-bind-try);;
		$conf_regex|$local_regex)
			bwrap_args+=(--bind-try);;
		*) bwrap_args+=(--ro-bind-try);;
	esac
	bwrap_args+=("$i"{,})
done

# Add user-defined isolated mounts
if [[ $full_isolation -eq 1 ]]; then
	user_args=("${isolated_user_mounts[@]}")
else
	user_args=("${normal_user_mounts[@]}")
fi
user_args+=("${shared_user_mounts[@]}")

# Add user-defined mounts to final bwrap args
for (( i=0; i<${#user_args[@]}; i++ )); do
	bwrap_args+=(--bind-try "${user_args[i]}" "${user_args[i+=1]}")
done
}

# Create isolated home directory and required shared dirs
mkdir -p $home_dir $conf_dir/faugus-launcher/components \
$local_dir/{Steam/compatibilitytools.d,umu}

# Parse options given by user
while getopts 'oxwifcvh' flag; do
	case $flag in
		o) net_access=1;;
		x) XDG_SESSION_TYPE=x11;;
		w) XDG_SESSION_TYPE=wayland;;
		i) gpu_select=integrated;;
		f) full_isolation=1;;
		c) create_dirs=1;;
		v) verbose_args=1;;
		h|*) help_msg;;
	esac
done
shift $((OPTIND - 1))

# Bind dirs required for sandbox functionality
apply_defined_dirs

# Grant/deny network access
if [[ $net_access -eq 0 ]]; then
	bwrap_args+=(--unshare-net)
fi

# Check if umu is available
if [[ -n ${binary_list[umu-run]} ]]; then
	bwrap_args+=(--ro-bind-try ${binary_list[umu-run]} $sandbox_umu)
elif [[ ! -s $local_umu ]]; then
	rm -f $local_umu
fi

# Check display session type
if [[ $XDG_SESSION_TYPE == x11 ]]; then
	bwrap_args+=(
	--ro-bind-try $XAUTHORITY{,}
	--ro-bind-try /tmp/.X11-unix/X${DISPLAY##*:}{,}
	--setenv PROTON_ENABLE_WAYLAND 0
	)
elif [[ $XDG_SESSION_TYPE == wayland ]]; then
	bwrap_args+=(
	--unsetenv DISPLAY
	--setenv PROTON_ENABLE_WAYLAND 1
	)
fi

# Select gpu based on user's choice
if [[ $gpu_select == integrated ]]; then
	select_gpu integrated
else
	select_gpu discrete
fi

# Create defined dirs that don't exist yet
if [[ $create_dirs -eq 1 ]]; then
	create_user_dirs
fi

# Print launch args if enabled
if [[ $verbose_args -eq 1 ]]; then
	echo -e "=== BWRAP ARGS ==="
	echo "${bwrap_args[@]}"
	echo -e "\n=== PRELAUNCH ARGS ==="
	echo "${pre_launch[@]}"
	echo -e "\n=== LAUNCH ARGS (BINARY) ==="
	echo "\${pre_launch[@]} ${binary_list[bwrap]} \${bwrap_args[@]} ${binary_list[faugus-launcher]} && exit"
	echo -e "\n=== LAUNCH ARGS (APPIMAGE) ==="
	echo "\${pre_launch[@]} ${binary_list[bwrap]} \${bwrap_args[@]} ${binary_list[faugus-launcher]} --appimage-extract-and-run && exit"
	echo ""
fi

# Isolates Faugus with bubblewrap
# If first command fails, rerun as an appimage
"${pre_launch[@]}" "${binary_list[bwrap]}" "${bwrap_args[@]}" "${binary_list[faugus-launcher]}" && exit
"${pre_launch[@]}" "${binary_list[bwrap]}" "${bwrap_args[@]}" "${binary_list[faugus-launcher]}" --appimage-extract-and-run && exit
