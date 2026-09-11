#!/bin/sh

# Minimal POSIX launcher for the Gradle Wrapper already tracked by this repository.
# Windows development continues to use gradlew.bat; Xcode invokes this file through /bin/sh.
set -eu

SCRIPT_DIR=$(dirname "$0")
APP_HOME=$(CDPATH= cd "$SCRIPT_DIR" && pwd -P)
CLASSPATH="$APP_HOME/gradle/wrapper/gradle-wrapper.jar"

if [ -n "${JAVA_HOME:-}" ]; then
    JAVACMD="$JAVA_HOME/bin/java"
else
    JAVACMD=java
fi

if [ ! -x "$JAVACMD" ] && [ -n "${JAVA_HOME:-}" ]; then
    echo "ERROR: JAVA_HOME points to a directory without bin/java: $JAVA_HOME" >&2
    exit 1
fi

exec "$JAVACMD" \
    "-Dorg.gradle.appname=gradlew" \
    -classpath "$CLASSPATH" \
    org.gradle.wrapper.GradleWrapperMain "$@"
