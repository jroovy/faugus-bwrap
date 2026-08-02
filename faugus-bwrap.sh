#!/usr/bin/env bash
script_name="${0##*/}"

bwrap=$(command -v bwrap)
faugus=$(command -v faugus-launcher)
switcheroo=$(command -v switcherooctl)

uid=$(id -u)
gid=$(id -g)

home_dir="$HOME/Bubblewrap/Faugus"
conf_dir="$HOME/.config"
cache_dir="$HOME/.cache"
local_dir="$HOME/.local/share"
local_umu="$home_dir/.local/share/faugus-launcher/umu-run"

# Extra shell options to prevent weird behavior
shopt -s nullglob extglob

# Reset important variables before start
unset bwrap_args pre_launch gpu_select

help_msg() {
echo "Options:
  -o = Enable network access (online)
  -x = Force use X11
  -w = Force use Wayland
  -i = Use integrated graphics
  -h = Show this help message

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

# Starting values to assign to found gpus
igpu_counter=0
dgpu_counter=0
has_nvidia=0

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
done < <($switcheroo list 2> /dev/null)
}

select_gpu() {
find_gpus
selection=1

# Silently switch to igpu if no dgpus are found
if [[ dgpu_counter -eq 0 || $1 == integrated ]]; then
	gpu_type=i
	gpu_count=$igpu_counter
elif [[ $1 == discrete ]]; then
	gpu_type=d
	gpu_count=$dgpu_counter
fi

if [[ gpu_count -gt 1 ]]; then
	echo "Multiple gpus detected! Select one:"
	for (( i=1; i<=gpu_count; i++ )); do
		echo "$i) ${gpu_names[$gpu_type$i]}"
	done
	echo -n "> "
	read -r selection
fi

if [[ -z "${gpu_names[$gpu_type$selection]}" ]]; then
	echo "Invalid gpu selection!"
	exit
fi

if [[ has_nvidia -eq 1 ]]; then
	pre_launch+=($switcheroo launch --gpu=${gpu_ids[$gpu_type$selection]})
else
	bwrap_args+=(--setenv DRI_PRIME "${gpu_ids[$gpu_type$selection]}!")
fi
}

apply_args() {
# Apply initial args
bwrap_args+=(
--die-with-parent

# Exclude unnecessary namespaces
--unshare-all
# --unshare-{user,ipc,pid,uts,cgroup}

# Map user id into sandbox
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

# List of directories to mount
bwrap_mounts=(
# Bind required devices for gaming
/dev/{{,u}input,shm,ntsync,snd,dri,hidraw*,nvidia*}

# Bind required stuff for umu to function
/etc/{fonts,resolv.conf,passwd,group,machine-id,ld.so.cache,pki}

# Bind required filesystem directories
/{usr/!(local|sbin)\
,lib{,64},bin,sys/{dev{,ices},class,bus},run/udev}

# Bind required user xdg sockets
$XDG_RUNTIME_DIR/\
{bus,{at-spi/bus_,pipewire-}+([0-9]),pulse/native,$WAYLAND_DISPLAY}

# Theming support (gtk/qt+kde)
$conf_dir/{gtk{rc{,-2.0},-{2..4}.0},kdeglobals}

# Share required dirs for faugus+umu functionality
$conf_dir/{faugus-launcher/components,Mangohud}
$local_dir/{Steam/compatibilitytools.d,umu}
)

# Add mountpoints to bwrap_args
for i in "${bwrap_mounts[@]}"; do
	case "$i" in
		/dev/*) bwrap_args+=(--dev-bind-try);;
		$conf_dir/faugus-*|$local_dir/umu?(/*)) bwrap_args+=(--bind-try);;
		*) bwrap_args+=(--ro-bind-try);;
	esac
	bwrap_args+=("$i"{,})
done
}

apply_user() {
user_mounts=(

# Mount game and storage dirs
/run/media/$USER
$HOME/Games

)

for i in "${user_mounts[@]}"; do
	bwrap_args+=(--bind-try "$i"{,})
done
}

apply_args
apply_user

# Create isolated home directory
mkdir -p $home_dir

while getopts 'oxwih' flag; do
	case $flag in
		o) bwrap_args+=(--share-net);;
		x) XDG_SESSION_TYPE=x11;;
		w) XDG_SESSION_TYPE=wayland; bwrap_args+=(--unsetenv DISPLAY);;
		i) gpu_select=integrated;;
		h|*) help_msg;;
	esac
done
shift $((OPTIND - 1))

# Check if umu is available
umu=$(command -v umu-run)
if [[ -n $umu ]]; then
	bwrap_args+=(--ro-bind-try $umu $local_dir/faugus-launcher/${umu##*/})
elif [[ ! -s $local_umu ]]; then
	rm -f $local_umu
fi

# Check display session type
if [[ $XDG_SESSION_TYPE == x11 ]]; then
	bwrap_args+=(
	--ro-bind-try $XAUTHORITY{,}
	--ro-bind-try /tmp/.X11-unix/X${DISPLAY##*:}{,}
	)
fi

if [[ $gpu_select == integrated ]]; then
	select_gpu integrated
else
	select_gpu discrete
fi

# echo "bwrap args:"
# echo "${bwrap_args[@]}"

"${pre_launch[@]}" "$bwrap" "${bwrap_args[@]}" "$faugus" && exit
"${pre_launch[@]}" "$bwrap" "${bwrap_args[@]}" "$faugus" --appimage-extract-and-run && exit
