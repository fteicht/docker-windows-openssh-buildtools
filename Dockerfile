# escape=\

ARG build_tools_version=16

# Use the latest Windows Server Core image
FROM mcr.microsoft.com/windows/servercore:ltsc2019 AS base

# The version of Visual Studio Build Tools we want to install
ARG build_tools_version=16
ENV BTVersion=${build_tools_version}

FROM base AS win-bt-16
ENV BTYear=2019

FROM base AS win-bt-17
ENV BTYear=2022

FROM win-bt-${build_tools_version} AS final
RUN echo "Building Windows Build Tools %BTVersion% - %BTYear%"
ARG build_tools_version=16

# The version of Python we want to install
ARG python_version=38
ENV PVersion=${python_version}
RUN IF NOT "%PVersion%" == "null" echo "Including Python %PVersion%"

# Restore the default Windows shell for correct batch processing.
SHELL ["cmd", "/S", "/C"]

# Install BuildTools
RUN \
    curl -SL --output VisualStudio.chman https://aka.ms/vs/%BTVersion%/release/channel \
    && curl -SL --output vs_buildtools.exe https://aka.ms/vs/%BTVersion%/release/vs_buildtools.exe \
    && (vs_buildtools.exe --quiet --wait --norestart --nocache \
        --installPath "C:\Program Files (x86)\Microsoft Visual Studio\%BTYear%\BuildTools" \
        --channelUri %CD%\VisualStudio.chman \
        --installChannelUri %CD%\VisualStudio.chman \
        --add Microsoft.VisualStudio.Workload.VCTools \
        --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 \
        --add Microsoft.VisualStudio.Component.VC.CMake.Project \
        --add Microsoft.VisualStudio.Component.TestTools.BuildTools \
        --add Microsoft.VisualStudio.Component.VC.ASAN \
        --add Microsoft.VisualStudio.Component.Windows10SDK.19041 \
        --remove Microsoft.VisualStudio.Component.Windows10SDK.10240 \
        --remove Microsoft.VisualStudio.Component.Windows10SDK.10586 \
        --remove Microsoft.VisualStudio.Component.Windows10SDK.14393 \
        --remove Microsoft.VisualStudio.Component.Windows81SDK \
    || IF "%ERRORLEVEL%"=="3010" EXIT 0) \
    && del vs_buildtools.exe \
    && del VisualStudio.chman

# Install Python
RUN \
    IF NOT "%PVersion%" == "null" \
        curl -SL --output Miniconda3.exe https://repo.anaconda.com/miniconda/Miniconda3-py%PVersion%_4.10.3-Windows-x86_64.exe \
        && start /wait Miniconda3.exe /InstallationType=AllUsers /RegisterPython=1 /AddToPath=1 /S /D=C:\Miniconda3
# We need to close and reopen the shell so that the conda program is registered and usable to init and update it
RUN \
    IF NOT "%PVersion%" == "null" \
        powershell -Command "conda init powershell" \
        && powershell -Command "conda update -n base -c defaults conda"

# Install Git
ENV GIT_VERSION 2.15.1
ENV GIT_PATCH_VERSION 2

RUN powershell -Command $ErrorActionPreference = 'Stop' ; \
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 ; \
    Invoke-WebRequest $('https://github.com/git-for-windows/git/releases/download/v{0}.windows.{1}/MinGit-{0}.{1}-busybox-64-bit.zip' -f $env:GIT_VERSION, $env:GIT_PATCH_VERSION) -OutFile 'mingit.zip' -UseBasicParsing ; \
    Expand-Archive mingit.zip -DestinationPath c:\mingit ; \
    Remove-Item mingit.zip -Force ; \
    setx /M PATH $('c:\mingit\cmd;{0}' -f $env:PATH)

# Install OpenSSH
SHELL ["powershell", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';"]
ENV SPINNER_VERSION 1.0.8
COPY install-openssh.ps1 install-openssh.ps1
RUN ./install-openssh.ps1

# Install Spinner to watch a Windows service
RUN \
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 ; \
    Invoke-WebRequest $('https://github.com/ticketmaster/spinner/releases/download/v{0}/spinner_windows_amd64-v{0}.zip' -f $env:SPINNER_VERSION) -OutFile spinner.zip -UseBasicParsing ; \
    Expand-Archive spinner.zip ; \
    Remove-Item spinner.zip ; \
    Move-Item spinner\spinner_v$env:SPINNER_VERSION.exe spinner.exe ; \
    Remove-Item spinner
# CMD Start-Sleep 5 ; ./spinner.exe service sshd -t C:\ProgramData\ssh\logs\sshd.log

# Start the SSH service
RUN Start-Job -ScriptBlock {& ./spinner.exe service sshd -t C:\ProgramData\ssh\logs\sshd.log}

# Create the DevUser account and its powershell session so that it will create its home folders,
# which is necessary to bind a host's folder to C:\Users\DevUser\Work when running the container.
# Creating DevUser's home folders must be done before ENTRYPOINT, otherwise Windows will create
# another DevUser in a different domain when binding a host's folder to C:\Users\DevUser\Work
# in the 'docker run' command invokation
RUN \
    $password = ConvertTo-SecureString 'Passw0rd' -AsPlainText -Force ; \
    New-LocalUser "DevUser" -Password $password ; \
    Add-LocalGroupMember -Group "Administrators" -Member "DevUser" ; \
    $credential = New-Object System.Management.Automation.PSCredential ".\DevUser", $password ; \
    New-PSSession -Credential $credential

# Define the entry point for the docker container.
# This entry point starts the developer command prompt and launches the PowerShell shell.int.ps1
COPY entrypoint.ps1 entrypoint.ps1
ENTRYPOINT [ "powershell.exe", "-NoLogo", "-NoExit", "C:\\entrypoint.ps1" ]
