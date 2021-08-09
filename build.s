export URM_CREDS_USR=timl
export URM_CREDS_PSW=AKCp5emRWbrqFqGBKQZ4KDg4YsXknijZe5WMkpLGiMm8pQo6XdZ7fvmCBcAce3XhugwG7CBBr
export URM_URL="https://urm.nvidia.com/artifactory/sw-spark-maven"
mvn install -s jenkins/settings.xml -nsu -Pscala-2.13 -DskipTests -pl sql-plugin/

