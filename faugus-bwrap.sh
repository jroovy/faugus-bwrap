#!/usr/bin/env bash
script_name="${0##*/}"

# Dynamically assign path values to required binaries
# instead of hardcoding them
umu=$(command -v umu-run)
bwrap=$(command -v bwrap)
faugus=$(command -v faugus-launcher)
switcherooctl=$(command -v switcherooctl)

# Store user and group id
uid=$(id -u)
gid=$(id -g)

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
unset bwrap_args user_args pre_launch gpu_select full_isolation verbose_args

help_msg() {
echo "A script that isolates Faugus and your games from the rest of the system using Bubblewrap

Options:
  -o = Enable network access (online)
  -x = Force use X11
  -w = Force use Wayland
  -i = Use integrated graphics
  -f = Run games in full isolation
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
# Arrays to store gpu names and id numbers
declare -Ag gpu_ids
declare -Ag gpu_names

# Clear values before scanning for gpus
unset gpu_type gpu_name gpu_id

# Initial values to assign to found gpus
igpu_counter=0
dgpu_counter=0

while IFS= read -r line; do
	# Find gpu ID number
	if [[ "$line" =~ Device:[[:space:]]*([0-9]+) ]]; then
		gpu_id="${BASH_REMATCH[1]}"
	fi

	# Get the gpu type
	if [[ "$line" =~ Discrete:[[:space:]]*(yes|no) ]]; then
		if [[ ${BASH_REMATCH[1]} == yes ]]; then
			gpu_type=d
		else
			gpu_type=i
		fi
	fi

	# Get the gpu name
	if [[ "$line" =~ Name:[[:space:]]*(.+) ]]; then
		gpu_name="${BASH_REMATCH[1]}"
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
done < <($switcherooctl list 2> /dev/null)
}

select_gpu() {
# Find available gpus before running the picker
find_gpus

# Pick first gpu by default
selection=1

# Silently switch to igpu if no dgpus are found
if [[ dgpu_counter -eq 0 || $1 == integrated ]]; then
	gpu_type=i
	gpu_count=$igpu_counter
elif [[ $1 == discrete ]]; then
	gpu_type=d
	gpu_count=$dgpu_counter
fi

# Ask user to pick a gpu if >1 are found
if [[ gpu_count -gt 1 ]]; then
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
pre_launch+=($switcherooctl launch --gpu=${gpu_ids[$gpu_type$selection]})
bwrap_args+=(--setenv DRI_PRIME "${gpu_ids[$gpu_type$selection]}!")
}

apply_required_args() {
# Apply initial args
bwrap_args+=(
--die-with-parent

# Exclude unnecessary namespaces
--unshare-all

# Map user and group id into sandbox
--uid $uid
--gid $gid

# Create basic dev structure
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

apply_defined_dirs() {
# Apply required args
apply_required_args

# Load defined dirs
define_required_dirs
define_isolation_dirs
define_user_dirs

# Add required isolated mounts
if [[ full_isolation -eq 1 ]]; then
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
if [[ full_isolation -eq 1 ]]; then
	user_args=("${isolated_user_mounts[@]}")
else
	user_args=("${normal_user_mounts[@]}")
fi
user_args+=("${shared_user_mounts[@]}")

# Add user-defined mounts to final bwrap args
for ((i=0; i<${#user_args[@]}; i++)); do
	bwrap_args+=(--bind-try "${user_args[i]}" "${user_args[i+=1]}")
done
}

# Create isolated home directory and required shared dirs
mkdir -p $home_dir $conf_dir/faugus-launcher/components \
$local_dir/{Steam/compatibilitytools.d,umu}

# Parse options given by user
while getopts 'oxwifvh' flag; do
	case $flag in
		o) bwrap_args+=(--share-net);;
		x) XDG_SESSION_TYPE=x11;;
		w) XDG_SESSION_TYPE=wayland;;
		i) gpu_select=integrated;;
		f) full_isolation=1;;
		v) verbose_args=1;;
		h|*) help_msg;;
	esac
done
shift $((OPTIND - 1))

# Bind dirs required for sandbox functionality
apply_defined_dirs

# Check if umu is available
if [[ -n $umu ]]; then
	bwrap_args+=(--ro-bind-try $umu $sandbox_umu)
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

# Print launch args if enabled
if [[ verbose_args -eq 1 ]]; then
	echo -e "=== BWRAP ARGS ==="
	echo "${bwrap_args[@]}"
	echo -e "\n=== PRELAUNCH ARGS ==="
	echo "${pre_launch[@]}"
	echo -e "\n=== LAUNCH ARGS (BINARY) ==="
	echo "\${pre_launch[@]} $bwrap \${bwrap_args[@]} $faugus && exit"
	echo -e "\n=== LAUNCH ARGS (APPIMAGE) ==="
	echo "\${pre_launch[@]} $bwrap \${bwrap_args[@]} $faugus --appimage-extract-and-run && exit"
	echo ""
fi

# Isolates Faugus with bubblewrap
# If first command fails, rerun as an appimage
"${pre_launch[@]}" "$bwrap" "${bwrap_args[@]}" "$faugus" && exit
"${pre_launch[@]}" "$bwrap" "${bwrap_args[@]}" "$faugus" --appimage-extract-and-run && exit
