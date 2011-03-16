## This script provides the framework for software version detection and
## parsing, but doesn't actually do any detection on it's own.  It relys on
## other protocol specific scripts to parse out software from the protocol(s)
## that they analyze.  The entry point for providing new software detections
## to this framework is through the Software::found function.

@load functions
@load notice

module Software;

redef enum Notice::Type += { 
	## For certain softwares, a version changing may matter.  In that case, 
	## this notice will be generated.  Software that matters if the version
	## changes can be configured with the 
	## Software::interesting_version_changes variable.
	Software_Version_Change,
};

export {
	type Version: record {
		major:  count &default=0;    ##< Major version number
		minor:  count &default=0;    ##< Minor version number
		minor2: count &default=0;    ##< Minor subversion number
		addl:   string &default="";  ##< Additional version string (e.g. "beta42")
	};

	type Type: enum {
		UNKNOWN_SOFTWARE,
		WEB_SERVER, 
		WEB_BROWSER,
		MAIL_SERVER, 
		MAIL_CLIENT,
		FTP_SERVER, 
		FTP_CLIENT,
		BROWSER_PLUGIN,
		WEBAPP,
		DATABASE_SERVER,
		## There are a number of ways to detect printers on the network.
		PRINTER,
	};

	redef enum Log::ID += { SOFTWARE };
	type Info: record {
		## The time at which the software was first detected.
		ts:               time;
		## The IP address detected running the software.
		host:             addr &default=0.0.0.0;
		## The type of software detected (e.g. WEB_SERVER)
		software_type:    Type &default=UNKNOWN_SOFTWARE;
		## Name of the software (e.g. Apache)
		name:             string;
		## Version of the software
		version:          Version;
		## The full unparsed version string found because the version parsing 
		## work 100% reliably and this acts as a fall back in the logs.
		unparsed_version: string;
	};
	
	## The hosts whose software should be logged.
	## Choices are: LocalHosts, RemoteHosts, Enabled, Disabled
	const logging = Enabled &redef;

	## In case you are interested in more than logging just local assets
	## you can split the log file.
	#const split_log_file = F &redef;
	
	## Some software is more interesting when the version changes.  This is
	## a set of all software that should raise a notice when a different version
	## is seen.
	const interesting_version_changes: set[string] = {
		"SSH"
	} &redef;
	
	## Other scripts should call this function when they detect software.
	## @param unparsed_version: This is the full string from which the
	##                          Software::Info was extracted.
	## @return: T if the software was logged, F otherwise.
	global found: function(c: connection, info: Software::Info): bool;
	
	## This function can take many software version strings and parse them into 
	## a sensible Software::Version record.  There are still many cases where
	## scripts may have to have their own specific version parsing though.
	global default_software_parsing: function(unparsed_version: string): Info;
	
	## Index is the name of the software.
	type SoftwareSet: table[string] of Info;
	# The set of software associated with an address.
	global tracked_software: table[addr] of SoftwareSet &create_expire=1day &synchronized;
}

event bro_init()
	{
	Log::create_stream("SOFTWARE", "Software::Info");
	Log::add_default_filter("SOFTWARE");
	}

function default_software_parsing(unparsed_version: string): Info
	{
	local software_name = "";
	local v: Version;

	# The regular expression should match the complete version number
	# TODO: this needs tests written!
	local version_parts = split_all(unparsed_version, /[0-9\-\._]{2,}/);
	if ( |version_parts| >= 2 )
		{
		# Remove the name/version separator
		software_name = sub(version_parts[1], /.$/, "");
		local version_numbers = split_n(version_parts[2], /[\-\._[:blank:]]/, F, 4);
		if ( |version_numbers| >= 4 )
			v$addl = version_numbers[4];
		if ( |version_numbers| >= 3 )
			v$minor2 = to_count(version_numbers[3]);
		if ( |version_numbers| >= 2 )
			v$minor = to_count(version_numbers[2]);
		if ( |version_numbers| >= 1 )
			v$major = to_count(version_numbers[1]);
		}
	return [$ts=network_time(), $host=0.0.0.0, $name=software_name,
	        $version=v, $unparsed_version=unparsed_version];
	}


# Compare two versions.
#   Returns -1 for v1 < v2, 0 for v1 == v2, 1 for v1 > v2.
#   If the numerical version numbers match, the addl string
#   is compared lexicographically.
function software_cmp_version(v1: Version, v2: Version): int
	{
	if ( v1$major < v2$major )
		return -1;
	if ( v1$major > v2$major )
		return 1;

	if ( v1$minor < v2$minor )
		return -1;
	if ( v1$minor > v2$minor )
		return 1;

	if ( v1$minor2 < v2$minor2 )
		return -1;
	if ( v1$minor2 > v2$minor2 )
		return 1;

	return strcmp(v1$addl, v2$addl);
	}

function software_endpoint_name(c: connection, host: addr): string
	{
	return fmt("%s %s", host, (host == c$id$orig_h ? "client" : "server"));
	}

# Convert a version into a string "a.b.c-x".
function software_fmt_version(v: Version): string
	{
	return fmt("%d.%d.%d%s", 
	           v$major, v$minor, v$minor2,
	           v$addl != ""  ? fmt("-%s", v$addl)   : "");
	}

# Convert a software into a string "name a.b.cx".
function software_fmt(i: Info): string
	{
	return fmt("%s %s", i$name, software_fmt_version(i$version));
	}

# Insert a mapping into the table
# Overides old entries for the same software and generates events if needed.
event software_register(c: connection, info: Info)
	{
	# Host already known?
	if ( info$host !in tracked_software )
		tracked_software[info$host] = table();

	local ts = tracked_software[info$host];
	# Software already registered for this host?
	if ( info$name in ts )
		{
		local old = ts[info$name];
		
		# Is it a potentially interesting version change 
		# and is it a different version?
		if ( info$name in interesting_version_changes &&
		     software_cmp_version(old$version, info$version) != 0 )
			{
			local msg = fmt("%.6f %s switched from %s to %s (%s)",
					network_time(), software_endpoint_name(c, info$host),
					software_fmt_version(old$version),
					software_fmt(info), info$software_type);
			NOTICE([$note=Software_Version_Change, $conn=c,
			        $msg=msg, $sub=software_fmt(info)]);
			}
		else
			{
			# If the software is known to be on this host already and version
			# changes either aren't interesting or it's the same version as
			# already known, just return and don't log.
			return;
			}
		}
		
	Log::write("SOFTWARE", info);
	ts[info$name] = info;
	}

function found(c: connection, info: Info): bool
	{
	if ( addr_matches_hosts(info$host, logging) )
		{
		event software_register(c, info);
		return T;
		}
	else
		return F;
	}
