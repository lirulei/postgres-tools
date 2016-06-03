#!/bin/sh
#
# The MIT License (MIT)
#
# Copyright (c) 2016 Jesper Pedersen <jesper.pedersen@comcast.net>
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the "Software"),
# to deal in the Software without restriction, including without limitation
# the rights to use, copy, modify, merge, publish, distribute, sublicense,
# and/or sell copies of the Software, and to permit persons to whom the Software
# is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
# INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
# PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
# HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
# SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#

SECONDS=0
DATE=`date +"%Y%m%d"`
CLIENTS="1 10 25 50 75 100 125 150 175 200"
SCALE=3000
TIME=180
PGSQL_ROOT=/opt/postgresql-9.6
PGSQL_DATA=/mnt/data/9.6
PGSQL_XLOG=/mnt/xlog/9.6
COMPILE_OPTIONS="--with-openssl --with-gssapi --enable-debug --enable-depend"
COMPILE_JOBS=60
CONFIGURATION=/home/postgres/Configuration/9.6
PATCHES=always
RUN_TWOPC=1

function postgresql_start()
{
    $PGSQL_ROOT/bin/pg_ctl -D $PGSQL_DATA -l $PGSQL_DATA/logfile start >> $DATE-$HEAD-build.log
    sleep 5
}

function postgresql_stop()
{
    $PGSQL_ROOT/bin/pg_ctl -D $PGSQL_DATA -l $PGSQL_DATA/logfile stop
    sleep 5
}

function postgresql_configuration()
{
    rm -Rf $PGSQL_DATA/* $PGSQL_XLOG/*
    $PGSQL_ROOT/bin/initdb -D $PGSQL_DATA -X $PGSQL_XLOG >> $DATE-$HEAD-build.log
    cp $CONFIGURATION/* $PGSQL_DATA
}

function postgresql_synchronous_commit()
{
    sed -i 's/synchronous_commit = off/synchronous_commit = on/g' $PGSQL_DATA/postgresql.conf
}

function postgresql_compile()
{
    cd postgres
    git checkout -q master
    git pull -q

    HEAD=`git rev-parse HEAD`

    git checkout -b $DATE -q master
    
    if [ -d "../$PATCHES" ]; then
        for f in ../$PATCHES/*.patch
        do
            patch -p1 < $f
        done
    fi

    git commit -a -m "$DATE"
    
    touch ../$DATE-$HEAD-build.log
    export CFLAGS="-O -fno-omit-frame-pointer" && ./configure --prefix $PGSQL_ROOT $COMPILE_OPTIONS >> ../$DATE-$HEAD-build.log
    make clean >> ../$DATE-$HEAD-build.log
    make -j $COMPILE_JOBS >> ../$DATE-$HEAD-build.log
    make install >> ../$DATE-$HEAD-build.log
    cd ..
}

function pgbench_init_logged()
{
    $PGSQL_ROOT/bin/createdb -E UTF8 pgbench >> $DATE-$HEAD-build.log
    $PGSQL_ROOT/bin/pgbench -i -s $SCALE -q pgbench >> $DATE-$HEAD-build.log
}

function pgbench_init_unlogged()
{
    $PGSQL_ROOT/bin/createdb -E UTF8 pgbench >> $DATE-$HEAD-build.log
    $PGSQL_ROOT/bin/pgbench -i -s $SCALE -q --unlogged-tables pgbench >> $DATE-$HEAD-build.log
}

function pgbench_1pc_standard()
{
    local FILE=$DATE-$HEAD-$1-$2-1pc-standard.txt
    touch $FILE
    for i in $CLIENTS; do
        echo "DATA "$i >> $FILE
        $PGSQL_ROOT/bin/pgbench -c $i -j $i -T $TIME -U postgres pgbench >> $FILE
        echo "" >> $FILE
    done
    echo -n "1PC "$1"/"$2": " >> $DATE-$HEAD-wal.txt
    $PGSQL_ROOT/bin/psql -c "SELECT pg_size_pretty(pg_xlog_location_diff(pg_current_xlog_location(), '0/0'));" pgbench | tail -3 | head -1 >> $DATE-$HEAD-wal.txt
}

function pgbench_1pc_prepared()
{
    local FILE=$DATE-$HEAD-$1-$2-1pc-prepared.txt
    touch $FILE
    for i in $CLIENTS; do
        echo "DATA "$i >> $FILE
        $PGSQL_ROOT/bin/pgbench -c $i -j $i -M prepared -T $TIME -U postgres pgbench >> $FILE
        echo "" >> $FILE
    done
    echo -n "1PCP "$1"/"$2": " >> $DATE-$HEAD-wal.txt
    $PGSQL_ROOT/bin/psql -c "SELECT pg_size_pretty(pg_xlog_location_diff(pg_current_xlog_location(), '0/0'));" pgbench | tail -3 | head -1 >> $DATE-$HEAD-wal.txt
}

function pgbench_readonly()
{
    local FILE=$DATE-$HEAD-$1-$2-readonly.txt
    touch $FILE
    for i in $CLIENTS; do
        echo "DATA "$i >> $FILE
        $PGSQL_ROOT/bin/pgbench -c $i -j $i -S -T $TIME -U postgres pgbench >> $FILE
        echo "" >> $FILE
    done
    echo -n "RO "$1"/"$2": " >> $DATE-$HEAD-wal.txt
    $PGSQL_ROOT/bin/psql -c "SELECT pg_size_pretty(pg_xlog_location_diff(pg_current_xlog_location(), '0/0'));" pgbench | tail -3 | head -1 >> $DATE-$HEAD-wal.txt
}

function pgbench_2pc_standard()
{
    local FILE=$DATE-$HEAD-$1-$2-2pc-standard.txt
    touch $FILE
    for i in $CLIENTS; do
        echo "DATA "$i >> $FILE
        $PGSQL_ROOT/bin/pgbench -c $i -j $i -X -T $TIME -U postgres pgbench >> $FILE
        echo "" >> $FILE
    done
    echo -n "2PC "$1"/"$2": " >> $DATE-$HEAD-wal.txt
    $PGSQL_ROOT/bin/psql -c "SELECT pg_size_pretty(pg_xlog_location_diff(pg_current_xlog_location(), '0/0'));" pgbench | tail -3 | head -1 >> $DATE-$HEAD-wal.txt
}

postgresql_stop
postgresql_compile

touch $DATE-$HEAD-wal.txt

# Off / Logged
postgresql_configuration
postgresql_start
pgbench_init_logged
pgbench_1pc_standard "off" "logged"

postgresql_stop
postgresql_configuration
postgresql_start
pgbench_init_logged
pgbench_1pc_prepared "off" "logged"

postgresql_stop
postgresql_configuration
postgresql_start
pgbench_init_logged
pgbench_readonly "off" "logged"

if [ $RUN_TWOPC == 1 ]; then
    postgresql_stop
    postgresql_configuration
    postgresql_start
    pgbench_init_logged
    pgbench_2pc_standard "off" "logged"
fi

# Off / Unlogged
postgresql_stop
postgresql_configuration
postgresql_start
pgbench_init_unlogged
pgbench_1pc_standard "off" "unlogged"

postgresql_stop
postgresql_configuration
postgresql_start
pgbench_init_unlogged
pgbench_1pc_prepared "off" "unlogged"

postgresql_stop
postgresql_configuration
postgresql_start
pgbench_init_unlogged
pgbench_readonly "off" "unlogged"

if [ $RUN_TWOPC == 1 ]; then
    postgresql_stop
    postgresql_configuration
    postgresql_start
    pgbench_init_unlogged
    pgbench_2pc_standard "off" "unlogged"
fi

# On / Logged
postgresql_stop
postgresql_configuration
postgresql_synchronous_commit
postgresql_start
pgbench_init_logged
pgbench_1pc_standard "on" "logged"

postgresql_stop
postgresql_configuration
postgresql_synchronous_commit
postgresql_start
pgbench_init_logged
pgbench_1pc_prepared "on" "logged"

postgresql_stop
postgresql_configuration
postgresql_synchronous_commit
postgresql_start
pgbench_init_logged
pgbench_readonly "on" "logged"

if [ $RUN_TWOPC == 1 ]; then
    postgresql_stop
    postgresql_configuration
    postgresql_synchronous_commit
    postgresql_start
    pgbench_init_logged
    pgbench_2pc_standard "on" "logged"
fi

# On / Unlogged
postgresql_stop
postgresql_configuration
postgresql_synchronous_commit
postgresql_start
pgbench_init_unlogged
pgbench_1pc_standard "on" "unlogged"

postgresql_stop
postgresql_configuration
postgresql_synchronous_commit
postgresql_start
pgbench_init_unlogged
pgbench_1pc_prepared "on" "unlogged"

postgresql_stop
postgresql_configuration
postgresql_synchronous_commit
postgresql_start
pgbench_init_unlogged
pgbench_readonly "on" "unlogged"

if [ $RUN_TWOPC == 1 ]; then
    postgresql_stop
    postgresql_configuration
    postgresql_synchronous_commit
    postgresql_start
    pgbench_init_unlogged
    pgbench_2pc_standard "on" "unlogged"
fi

# PostgreSQL configuration
cp $CONFIGURATION/postgresql.conf $DATE-$HEAD-postgresql-conf.txt

# Environment
cat /etc/system-release > $DATE-$HEAD-environment.txt
cat /proc/version >> $DATE-$HEAD-environment.txt
gcc --version >> $DATE-$HEAD-environment.txt

# Build time
echo "Seconds: "$SECONDS >> $DATE-$HEAD-build.log
