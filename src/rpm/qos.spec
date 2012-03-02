
%define name        qos
%define svcname     %{name}

%define initdir     %{_sysconfdir}/init.d
%define netconfdir  %{_sysconfdir}/sysconfig/network
%define qosconfig   %{netconfdir}/%{svcname}
%define modprobe    /sbin/modprobe
%define tcutil      %{_sbindir}/tc
%define iputil      /bin/ip
%define fillupdir   %{_var}/adm/fillup-templates

Name:               %{name}
Version:            %{git_version}
Release:            1
Buildarch:          noarch
Summary:            A Simple Linux QoS Service
Group:              System/Management
License:            Apache License, Version 2.0
Source0:            %{name}.zip
BuildRoot:          %{_tmppath}/%{name}-root
URL:                https://github.com/archiecobbs/qos
Requires:           iproute2
Requires(post):     fillup

%description
The Problem: Bufferbloat (see http://en.wikipedia.org/wiki/Bufferbloat)

    - Your SSH session turns to molasses when your kid watches YouTube
    - Your wife complains that "the internet is slow"
    - You hate the stupid DSL modems supplied by the phone company
      with their giant packet queues that add unnecessary latency
    - You have your own Linux router that routes all your traffic
      or is the only machine you have connected to the Internet
      and know there must be a better way

The Solution: QoS

    QoS = "Quality of Service"

    You probably already know about it. Control and proritize traffic.

    This QoS is new and improved. Previous QoS setups only throttled
    traffic in the download direction. This one handles both directions
    using the (poorly documented) Linux ifb interface and tc(8) 'mirred'
    redirection.

%prep
%setup -c

%build
subst()
{
    sed -r \
        -e 's|@qosconfig@|%{qosconfig}|g' \
        -e 's|@modprobe@|%{modprobe}|g' \
        -e 's|@iputil@|%{iputil}|g' \
        -e 's|@tcutil@|%{tcutil}|g'
}
subst < scripts/%{svcname}.sh > %{svcname}

%install

# Install init script
install -d -m 0755 ${RPM_BUILD_ROOT}%{initdir}
install -m 0755 %{svcname} ${RPM_BUILD_ROOT}%{initdir}/

# Install sysconfig template
install -d -m 0755 ${RPM_BUILD_ROOT}%{fillupdir}
install -m 0755 fillup/sysconfig.%{svcname} ${RPM_BUILD_ROOT}%{fillupdir}/

%post
%{fillup_only -n -d %{svcname} network}

%preun
%{stop_on_removal %{svcname}}

%files
%attr(0755,root,root) %{initdir}/*
%attr(0644,root,root) %{fillupdir}/*
