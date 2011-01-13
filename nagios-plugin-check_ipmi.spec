%define		plugin	check_ipmi
Summary:	Nagios plugin to check IPMI status
Name:		nagios-plugin-%{plugin}
Version:	1.9
Release:	1
License:	GPL v2
Group:		Networking
Source0:	%{plugin}
Source1:	%{plugin}.cfg
Source2:	README
BuildRequires:	rpmbuild(macros) >= 1.552
Requires:	grep
Requires:	ipmitool
Requires:	nagios-common >= 3.2.3-3
Requires:	nagios-plugins-libs
Requires:	sed
Requires:	sudo
BuildArch:	noarch
BuildRoot:	%{tmpdir}/%{name}-%{version}-root-%(id -u -n)

%define		_sysconfdir	/etc/nagios/plugins
%define		plugindir	%{_prefix}/lib/nagios/plugins
%define		cachedir	/var/spool/nagios
%define		cachefile	%{cachedir}/%{plugin}.sdr

%description
Nagios plugin to check IPMI status.

%prep
%setup -qcT
cp -p %{SOURCE0} %{plugin}
cp -p %{SOURCE2} .

ver=$(awk '/REVISION=/{print $3}' %{plugin})
if [ "$ver" != %{version} ]; then
	exit 1
fi

%install
rm -rf $RPM_BUILD_ROOT
install -d $RPM_BUILD_ROOT{%{_sysconfdir},%{plugindir},%{cachedir}}
install -p %{plugin} $RPM_BUILD_ROOT%{plugindir}/%{plugin}
sed -e 's,@plugindir@,%{plugindir},' %{SOURCE1} > $RPM_BUILD_ROOT%{_sysconfdir}/%{plugin}.cfg
touch $RPM_BUILD_ROOT%{cachefile}

%clean
rm -rf $RPM_BUILD_ROOT

%post
if [ "$1" = 1 ]; then
	# setup sudo rules on first install
	%{plugindir}/%{plugin} -S %{cachefile} || :
fi

%postun
if [ "$1" = 0 ]; then
	# remove all sudo rules related to us
	%{__sed} -i -e '/CHECK_IPMI/d' /etc/sudoers
fi

%triggerin -- nagios-nrpe
%nagios_nrpe -a %{plugin} -f %{_sysconfdir}/%{plugin}.cfg

%triggerun -- nagios-nrpe
%nagios_nrpe -d %{plugin} -f %{_sysconfdir}/%{plugin}.cfg

%files
%defattr(644,root,root,755)
%doc README
%attr(640,root,nagios) %config(noreplace) %verify(not md5 mtime size) %{_sysconfdir}/%{plugin}.cfg
%attr(755,root,root) %{plugindir}/%{plugin}
%ghost %{cachefile}
