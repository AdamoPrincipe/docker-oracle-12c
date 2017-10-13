#!/bin/bash
set -e

# Prevent owner issues on mounted folders

mkdir /u01/oradata 
chown -R oracle:dba /u01
rm -f /u01/app/oracle/product
ln -s /u01/app/oracle-product /u01/app/oracle/product

#Run Oracle root scripts
/u01/app/oraInventory/orainstRoot.sh > /dev/null 2>&1
echo | /u01/app/oracle/product/12.1.0/xe/root.sh > /dev/null 2>&1 || true

if [ -z "$CHARACTER_SET" ]; then
	if [ "${USE_UTF8_IF_CHARSET_EMPTY}" == "true" ]; then
		export CHARACTER_SET="AMERICAN_AMERICA.WE8MSWIN1252"
	fi
fi
#NLS_NCHAR_CHARACTERSET=AL16UTF16
#NLS_LANG= AMERICAN_AMERICA.WE8MSWIN1252

if [ -n "$CHARACTER_SET" ]; then
	export CHARSET_MOD="NLS_LANG=$CHARACTER_SET"
	export CHARSET_INIT="-characterSet $CHARACTER_SET"
fi


impdp () {
	set +e
	DUMP_FILE=$(basename "$1")
	DUMP_NAME=${DUMP_FILE%.dmp} 
	cat > /tmp/impdp.sql << EOL
-- Impdp User
CREATE USER IMPDP IDENTIFIED BY IMPDP;
ALTER USER IMPDP ACCOUNT UNLOCK;
GRANT dba TO IMPDP WITH ADMIN OPTION;
-- New Scheme User
CREATE TABLESPACE SANKHYA DATAFILE '/u01/oradata/sankhya_1.dbf' SIZE 1024M AUTOEXTEND ON NEXT 64M MAXSIZE UNLIMITED;
ALTER TABLESPACE SANKHYA ADD DATAFILE '/u01/oradata/sankhya_2.dbf' SIZE 1024M AUTOEXTEND ON NEXT 64M MAXSIZE UNLIMITED;

CREATE TABLESPACE SANKIND DATAFILE '/u01/oradata/sankind_1.dbf' SIZE 1024M AUTOEXTEND ON NEXT 64M MAXSIZE UNLIMITED;
ALTER TABLESPACE SANKIND ADD DATAFILE '/u01/oradata/sankind_2.dbf' SIZE 1024M AUTOEXTEND ON NEXT 64M MAXSIZE UNLIMITED;

CREATE TABLESPACE SANKLOB DATAFILE '/u01/oradata/sanklob_1.dbf' SIZE 512M AUTOEXTEND ON NEXT 64M MAXSIZE UNLIMITED;
ALTER TABLESPACE SANKLOB ADD DATAFILE '/u01/oradata/sanklob_2.dbf' SIZE 512M AUTOEXTEND ON NEXT 64M MAXSIZE UNLIMITED;


CREATE USER DESEXTERNO IDENTIFIED BY "tecsis" DEFAULT TABLESPACE SANKHYA TEMPORARY TABLESPACE TEMP;
GRANT RESOURCE, CONNECT TO DESEXTERNO;
ALTER USER DESEXTERNO QUOTA UNLIMITED ON SANKHYA;
ALTER USER DESEXTERNO QUOTA UNLIMITED ON SANKIND;
ALTER USER DESEXTERNO QUOTA UNLIMITED ON SANKLOB;
GRANT SELECT ON V_$SESSION TO DESEXTERNO;
GRANT SELECT ON DBA_TABLES TO DESEXTERNO;
GRANT CREATE SESSION TO DESEXTERNO;
GRANT SELECT ON DBA_TAB_COLUMNS TO DESEXTERNO;
GRANT SELECT ON DBA_CONSTRAINTS TO DESEXTERNO;
GRANT SELECT ON DBA_TRIGGERS TO DESEXTERNO;
GRANT SELECT ON DBA_INDEXES TO DESEXTERNO;
GRANT SELECT ON DBA_VIEWS TO DESEXTERNO;
GRANT SELECT ON DBA_IND_COLUMNS TO DESEXTERNO;
GRANT SELECT ON DBA_OBJECTS TO DESEXTERNO;
GRANT SELECT ON DBA_PROCEDURES TO DESEXTERNO;
GRANT SELECT ON DBA_CONS_COLUMNS TO DESEXTERNO;
GRANT CREATE ANY VIEW TO DESEXTERNO;
GRANT DEBUG ANY PROCEDURE TO DESEXTERNO;
GRANT DEBUG CONNECT SESSION TO DESEXTERNO;
create or replace directory IMPDP as '/docker-entrypoint-initdb.d';
exit;
EOL

	#wget -o /docker-entrypoint-initdb.d/DESEXTERNO.dmp  http://desbh.sankhya.com.br/files/DESEXTERNO.dmp
	#wget -o /tmp/create.sql http://desbh.sankhya.com.br/files/create.sql

	#su oracle -c "$CHARSET_MOD $ORACLE_HOME/bin/sqlplus -S / as sysdba @/tmp/create.sql"
	su oracle -c "$CHARSET_MOD $ORACLE_HOME/bin/sqlplus -S / as sysdba @/tmp/impdp.sql"
	su oracle -c "$CHARSET_MOD $ORACLE_HOME/bin/impdp IMPDP/IMPDP directory=IMPDP dumpfile=DESEXTERNO.dmp SCHEMAS=DESEXTERNO $IMPDP_OPTIONS"
	#Disable IMPDP user
	echo -e 'ALTER USER IMPDP ACCOUNT LOCK;\nexit;' | su oracle -c "$CHARSET_MOD $ORACLE_HOME/bin/sqlplus -S / as sysdba"
	#wget -o /tmp/create.sql http://desbh.sankhya.com.br/files/postimport.sql

	echo -e 'ALTER USER DESEXTERNO identified by tecsis;\nexit;' | su oracle -c "$CHARSET_MOD $ORACLE_HOME/bin/sqlplus -S / as sysdba"
	set -e
}

case "$1" in
	'')
		#Check for mounted database files
		if [ "$(ls -A /u01/app/oracle/oradata 2>/dev/null)" ]; then
			echo "found files in /u01/app/oracle/oradata Using them instead of initial database"
			echo "XE:$ORACLE_HOME:N" >> /etc/oratab
			chown oracle:dba /etc/oratab
			chmod 664 /etc/oratab
			rm -rf /u01/app/oracle-product/12.1.0/xe/dbs
			ln -s /u01/app/oracle/dbs /u01/app/oracle-product/12.1.0/xe/dbs
			#Startup Database
			su oracle -c "/u01/app/oracle/product/12.1.0/xe/bin/tnslsnr &"
			su oracle -c 'echo startup\; | $ORACLE_HOME/bin/sqlplus -S / as sysdba'
		else
			echo "Database not initialized. Initializing database."
			export IMPORT_FROM_VOLUME=true


			#printf "Setting up:\nprocesses=$processes\nsessions=$sessions\ntransactions=$transactions\n"
			set +e
			mv /u01/app/oracle-product/12.1.0/xe/dbs /u01/app/oracle/dbs
			set -e

			ln -s /u01/app/oracle/dbs /u01/app/oracle-product/12.1.0/xe/dbs

			echo "Starting tnslsnr"
			su oracle -c "/u01/app/oracle/product/12.1.0/xe/bin/tnslsnr &"
			#create DB for SID: xe
			su oracle -c "$ORACLE_HOME/bin/dbca -silent -createDatabase -templateName General_Purpose.dbc -gdbname xe -sid xe -responseFile NO_VALUE $CHARSET_INIT -totalMemory $DBCA_TOTAL_MEMORY -emConfiguration LOCAL -pdbAdminPassword oracle -sysPassword oracle -systemPassword oracle"
			
			echo "Configuring Apex console"
			cd $ORACLE_HOME/apex
			su oracle -c 'echo -e "0Racle$\n8080" | $ORACLE_HOME/bin/sqlplus -S / as sysdba @apxconf > /dev/null'
			su oracle -c 'echo -e "${ORACLE_HOME}\n\n" | $ORACLE_HOME/bin/sqlplus -S / as sysdba @apex_epg_config_core.sql > /dev/null'
			su oracle -c 'echo -e "ALTER USER ANONYMOUS ACCOUNT UNLOCK;" | $ORACLE_HOME/bin/sqlplus -S / as sysdba > /dev/null'
			echo "Database initialized. Please visit http://#containeer:8080/em http://#containeer:8080/apex for extra configuration if needed"
		fi

		if [ $WEB_CONSOLE == "true" ]; then
			echo 'Starting web management console'
			su oracle -c 'echo EXEC DBMS_XDB.sethttpport\(8080\)\; | $ORACLE_HOME/bin/sqlplus -S / as sysdba'
		else
			echo 'Disabling web management console'
			su oracle -c 'echo EXEC DBMS_XDB.sethttpport\(0\)\; | $ORACLE_HOME/bin/sqlplus -S / as sysdba'
		fi

		if [ $IMPORT_FROM_VOLUME ]; then
			echo "Starting import from '/docker-entrypoint-initdb.d':"

			for f in /docker-entrypoint-initdb.d/*; do
				echo "found file /docker-entrypoint-initdb.d/$f"
				case "$f" in
					*.sh)     echo "[IMPORT] $0: running $f"; . "$f" ;;
					*.sql)    echo "[IMPORT] $0: running $f"; echo "exit" | su oracle -c "$CHARSET_MOD $ORACLE_HOME/bin/sqlplus -S / as sysdba @$f"; echo ;;
					*.dmp)    echo "[IMPORT] $0: running $f"; impdp $f ;;
					*)        echo "[IMPORT] $0: ignoring $f" ;;
				esac
				echo
			done

			echo "Import finished"
			echo
		else
			echo "[IMPORT] Not a first start, SKIPPING Import from Volume '/docker-entrypoint-initdb.d'"
			echo "[IMPORT] If you want to enable import at any state - add 'IMPORT_FROM_VOLUME=true' variable"
			echo
		fi

		echo "Database ready to use. Enjoy! ;)"

		##
		## Workaround for graceful shutdown.
		##
		while [ "$END" == '' ]; do
			sleep 1
			trap "su oracle -c 'echo shutdown immediate\; | $ORACLE_HOME/bin/sqlplus -S / as sysdba'" INT TERM
		done
		;;

	*)
		echo "Database is not configured. Please run '/entrypoint.sh' if needed."
		exec "$@"
		;;
esac
