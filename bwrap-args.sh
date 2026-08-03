apply_args() {
unset bwrap_args

# Apply initial args
bwrap_args+=(
--die-with-parent

# Exclude unnecessary namespaces
--unshare-all
# --unshare-{user,ipc,pid,uts,cgroup}

# Map user id into sandbox
--uid $(id -u)
--gid $(id -g)

# Create basic dev structure
--dev /dev
--proc /proc

# Create writable /tmp
--tmpfs /tmp

# Isolate home dir to another folder
--bind $home_dir $HOME

# Link umu-run to faugus local dir
--symlink $umu $local_dir/share/faugus-launcher/${umu##*/}

# Query and set current gtk theme
--setenv GTK_THEME $(gsettings get org.gnome.desktop.interface gtk-theme | tr -d "'")
)

# List of directories to mount
bwrap_mounts=(
# Bind required devices for gaming
/dev/{{,u}input,shm,ntsync,snd,dri,hidraw*,nvidia*}

# Bind required stuff for umu to function
/etc/{fonts,resolv.conf,passwd,group,machine-id,ld.so.cache}

# Bind required filesystem directories
/{usr/{bin,lib{,64,exec},share,},\
lib{,64},bin,sys/{dev{,ices},class,bus},run/udev}

# Bind required user xdg sockets
$XDG_RUNTIME_DIR/\
{bus,pipewire-+([0-9]),pulse/native,$WAYLAND_DISPLAY}

# Theming support (gtk/qt+kde)
$conf_dir/{gtk{rc{,-2.0},-{2..4}.0},kdeglobals}

# Share required dirs for faugus+umu functionality
$conf_dir/{faugus-launcher/components,Mangohud}
$local_dir/{Steam/compatibilitytools.d,umu}

# Mount game and storage dirs
/run/media/$USER
$HOME/Games
)

# Add mountpoints to bwrap_args
for i in "${bwrap_mounts[@]}"; do
	case "$i" in
		/dev/*) bwrap_args+=(--dev-bind-try);;
		/run/media/*|*$conf_dir/faugus-*\
		|*Games*|$local_dir/umu*) bwrap_args+=(--bind-try);;
		*) bwrap_args+=(--ro-bind-try);;
	esac
	bwrap_args+=("$i"{,})
done
}
