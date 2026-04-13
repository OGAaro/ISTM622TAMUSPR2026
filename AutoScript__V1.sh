#!/bin/bash

#===============================================================================================================================
# AUTOSCRIPT__V1 — Fully Automated POS Database Pipeline                                                                       =
#                                                                                                                              =
# Amazon EC2 User Data Bootstrap Script                                                                                        =
# Author:  Aaron Daniels                                                                                                       =
# Course:  ISTM 622 — Texas A&M University — Spring 2026                                                                       =
#                                                                                                                              =
# This script provisions a fresh Ubuntu EC2 instance end-to-end:                                                               =
#   1. Installs MariaDB 11.8 from the official repository                                                                      =
#   2. Creates an unprivileged application user with least-privilege access                                                    =
#   3. Downloads and stages raw CSV data files                                                                                 =
#   4. Runs a full ETL pipeline (Extract → Transform → Load) into a relational POS schema                                      =
#   5. Creates views, materialized views, and triggers for real-time data integrity                                            =
#   6. Exports nested JSON documents from the relational schema via SELECT ... INTO OUTFILE                                    =
#   7. Installs MongoDB 8.0 and imports JSON exports into document collections                                                 =
#   8. Establishes a cron-based sync pipeline to keep MongoDB in sync with MariaDB                                             =
#                                                                                                                              =
#-------------------------------------------------------------------------------------------------------------------------------
#                                                                                                                              =
# TABLE OF CONTENTS                                                                                                            =
# -----------------                                                                                                            =
# Search for the bracketed tag (e.g. [SEC-01]) to jump to each section.                                                        =
#                                                                                                                              =
#   [SEC-01]  LOGGING & ENVIRONMENT SETUP                                                                                      =
#   [SEC-02]  SYSTEM PACKAGE UPDATES                                                                                           =
#   [SEC-03]  WORDPRESS DIRECTORY SCAFFOLDING                                                                                  =
#   [SEC-04]  PURGE UBUNTU-REPO MARIADB                                                                                        =
#   [SEC-05]  INSTALL MARIADB 11.8 (OFFICIAL REPO)                                                                             =
#   [SEC-06]  CREATE UNPRIVILEGED OS USER                                                                                      =
#   [SEC-07]  CONFIGURE SUDO & SHELL ENVIRONMENT                                                                               =
#   [SEC-08]  DOWNLOAD & EXTRACT CSV DATA FILES                                                                                =
#   [SEC-09]  CREATE MARIADB DATABASE & APPLICATION USER                                                                       =
#   [SEC-10]  ETL SCRIPT — SCHEMA CREATION                                                                                     =
#   [SEC-11]  ETL SCRIPT — STAGING TABLE CREATION & DATA LOAD                                                                  =
#   [SEC-12]  ETL SCRIPT — TRANSFORM & VALIDATE STAGING DATA                                                                   =
#   [SEC-13]  ETL SCRIPT — LOAD INTO PRODUCTION TABLES                                                                         =
#   [SEC-14]  ETL SCRIPT — TEARDOWN (DROP STAGING TABLES & source_id)                                                          =
#   [SEC-15]  ETL SCRIPT — EXECUTE                                                                                             =
#   [SEC-16]  VIEWS & MATERIALIZED VIEWS                                                                                       =
#   [SEC-17]  TRIGGERS (ORDERLINE SYNC & PRICE HISTORY)                                                                        =
#   [SEC-18]  VIEWS/TRIGGERS SCRIPT — EXECUTE                                                                                  =
#   [SEC-19]  JSON EXPORT — DIRECTORY SETUP                                                                                    =
#   [SEC-20]  JSON EXPORT — prod.json (PRODUCT → CUSTOMERS)                                                                    =
#   [SEC-21]  JSON EXPORT — cust.json (CUSTOMER → ORDERS → ITEMS)                                                              =
#   [SEC-22]  JSON EXPORT — custom1.json (REGIONAL SALES DASHBOARD)                                                            =
#   [SEC-23]  JSON EXPORT — custom2.json (CUSTOMER LIFETIME VALUE)                                                             =
#   [SEC-24]  JSON EXPORT SCRIPT — EXECUTE                                                                                     =
#   [SEC-25]  INSTALL MONGODB 8.0                                                                                              =
#   [SEC-26]  MONGODB SYNC PIPELINE (sync.sh)                                                                                  =
#   [SEC-27]  CRON JOB — SCHEDULED SYNC                                                                                        =
#                                                                                                                              =
#===============================================================================================================================


# ==============================================================
# [SEC-01] LOGGING & ENVIRONMENT SETUP
# ==============================================================
# Redirect all stdout/stderr to /var/log/user-data.log for
# post-launch debugging. Also tee to the system console so
# progress is visible in the EC2 system log.
# ==============================================================

exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

## Must set script to noninteractive to perform an unattended installation
export DEBIAN_FRONTEND=noninteractive
echo "=== [SEC-01] Script started ==="
touch /root/1-script-started


# ==============================================================
# [SEC-02] SYSTEM PACKAGE UPDATES
# ==============================================================
# Ensure the latest security patches and package metadata
# are applied before any software installation begins.
# ==============================================================

echo "=== [SEC-02] Updating and upgrading system packages ==="
apt update
apt upgrade -y

touch /root/2-packages-upgraded
echo "System packages updated successfully."


# ==============================================================
# [SEC-03] WORDPRESS DIRECTORY SCAFFOLDING
# ==============================================================
# Install and immediately remove the wordpress package to
# scaffold the required directory structure and config files
# needed for a later manual WordPress installation (the
# official package bundles an outdated version).
# ==============================================================

echo "=== [SEC-03] Installing and removing WordPress to scaffold directories ==="
apt install wordpress -y
apt remove wordpress -y

touch /root/3-wordpress-shortcut-installed
echo "WordPress scaffolding complete."


# ==============================================================
# [SEC-04] PURGE UBUNTU-REPO MARIADB
# ==============================================================
# The wordpress package pulls in the Ubuntu-repo version of
# MariaDB as a dependency. Purge it completely to prevent
# version conflicts with the official MariaDB 11.8 repo.
# ==============================================================

apt remove --purge -y mariadb-server mariadb-client mariadb-common mysql-common 2>/dev/null || true
apt autoremove -y
apt autoclean -y

touch /root/3b-mariadb-ubuntu-version-purged


# ==============================================================
# [SEC-05] INSTALL MARIADB 11.8 (OFFICIAL REPO)
# ==============================================================
# Add the official MariaDB signing key and APT source, then
# install MariaDB Server 11.8. The service starts automatically
# on Ubuntu after installation.
# ==============================================================

echo "=== [SEC-05] Installing dependencies and adding MariaDB repository ==="
apt install apt-transport-https curl -y
mkdir -p /etc/apt/keyrings
curl -fsSL -o /etc/apt/keyrings/mariadb-keyring.pgp 'https://mariadb.org/mariadb_release_signing_key.pgp'
echo "MariaDB signing key downloaded."

cat > /etc/apt/sources.list.d/mariadb.sources <<'EOF'
# MariaDB 11.8 repository list - created 2026-02-06 00:46 UTC
# https://mariadb.org/download/
X-Repolib-Name: MariaDB
Types: deb
# URIs: https://deb.mariadb.org/11.8/ubuntu
URIs: https://mirrors.accretive-networks.net/mariadb/repo/11.8/ubuntu
Suites: noble
Components: main main/debug
Signed-By: /etc/apt/keyrings/mariadb-keyring.pgp
EOF
echo "MariaDB repository added."

echo "=== [SEC-05] Installing MariaDB Server ==="
apt update
apt install mariadb-server -y

touch /root/4-mariadb-installed
echo "MariaDB installed successfully."
echo "=== Installation Complete ==="


# ==============================================================
# [SEC-06] CREATE UNPRIVILEGED OS USER
# ==============================================================
# Create the application service user with a home directory
# and bash shell. Password login is locked — SSH key auth
# only (EC2 best practice). The same .pem key as the ubuntu
# user is copied so the user can SSH in directly.
# ==============================================================

echo "=== [SEC-06] Create Unprivileged User Started ==="
USERNAME="adaniels"
PASSWORD='$tr0ngpassword'
COMMENT="Application Service User"
UIN="531002509"
SSH_DIR="/home/${USERNAME}/.ssh"

echo "=== [SEC-06] Create User with Home Directory ==="
useradd -m -s /bin/bash -c "$COMMENT" "$USERNAME"

# Lock password login (SSH key auth only)
passwd -l "$USERNAME"

# Set up SSH key access using the same .pem key as the ubuntu user
mkdir -p "$SSH_DIR"
cp /home/ubuntu/.ssh/authorized_keys "$SSH_DIR/authorized_keys"
chown -R "${USERNAME}:${USERNAME}" "$SSH_DIR"
chmod 700 "$SSH_DIR"
chmod 600 "$SSH_DIR/authorized_keys"

# Ensure user has NO elevated group membership
gpasswd -d "$USERNAME" sudo    2>/dev/null || true
gpasswd -d "$USERNAME" adm     2>/dev/null || true
gpasswd -d "$USERNAME" dialout 2>/dev/null || true


# ==============================================================
# [SEC-07] CONFIGURE SUDO & SHELL ENVIRONMENT
# ==============================================================
# Grant the unprivileged user targeted sudo access to the
# mariadb binary ONLY — no other root privileges. A shell
# alias lets the user type 'mariadb' without 'sudo'.
# ==============================================================

cat > /etc/sudoers.d/${USERNAME}-mariadb <<EOF
# Allow ${USERNAME} to execute mariadb only — no other sudo privileges
${USERNAME} ALL=(root) NOPASSWD: /usr/bin/mariadb, /usr/sbin/mariadb
EOF

chmod 440 /etc/sudoers.d/${USERNAME}-mariadb

echo "alias mariadb='sudo mariadb'" >> /home/${USERNAME}/.bashrc
chown "${USERNAME}:${USERNAME}" /home/${USERNAME}/.bashrc

touch /root/5-nonprivuser-created

echo "User '${USERNAME}' created successfully on $(date)" >> /var/log/user-data.log
id "$USERNAME" >> /var/log/user-data.log


# ==============================================================
# [SEC-08] DOWNLOAD & EXTRACT CSV DATA FILES
# ==============================================================
# Install unzip, download the student-specific data bundle
# from the course server, and extract the CSV files into
# the application user's home directory.
# ==============================================================

apt install unzip -y
touch /root/6-unzip-installed

sudo -u ${USERNAME} wget -O /home/${USERNAME}/${UIN}.zip https://622.gomillion.org/data/${UIN}.zip
touch /root/7-downlod-CSV-zip

sudo -u ${USERNAME} unzip /home/${USERNAME}/${UIN}.zip -d /home/${USERNAME}
touch /root/8-unzipped-CSV-files


# ==============================================================
# [SEC-09] CREATE MARIADB DATABASE & APPLICATION USER
# ==============================================================
# Create the POS database and the application-level MariaDB
# user. GRANT ALL on POS.* provides schema-level privileges,
# while GRANT FILE ON *.* is a separate global privilege
# required for SELECT ... INTO OUTFILE (JSON exports).
# ==============================================================

mariadb -e "CREATE USER IF NOT EXISTS '${USERNAME}'@'localhost' IDENTIFIED BY '${PASSWORD}';"
mariadb -e "DROP DATABASE IF EXISTS POS;"
mariadb -e "CREATE DATABASE POS;"
mariadb -e "GRANT ALL PRIVILEGES ON POS.* TO '${USERNAME}'@'localhost' WITH GRANT OPTION;"
mariadb -e "GRANT FILE ON *.* TO 'adaniels'@'localhost';"
mariadb -e "FLUSH PRIVILEGES;"


# ==============================================================
# [SEC-10] ETL SCRIPT — SCHEMA CREATION
# [SEC-11] ETL SCRIPT — STAGING TABLE CREATION & DATA LOAD
# [SEC-12] ETL SCRIPT — TRANSFORM & VALIDATE STAGING DATA
# [SEC-13] ETL SCRIPT — LOAD INTO PRODUCTION TABLES
# [SEC-14] ETL SCRIPT — TEARDOWN (DROP STAGING & source_id)
# ==============================================================
# The entire ETL pipeline is written as a single SQL file
# (etl.sql) and executed in one pass. Internal sections are
# marked with comments matching the TOC tags above.
#
# Key design decisions:
#   - SERIAL PKs are BIGINT UNSIGNED; FKs must match
#   - `Order` is backtick-quoted (reserved keyword)
#   - Staging tables use VARCHAR for all inbound fields
#     to absorb dirty data before type-casting
#   - source_id columns are added temporarily to map
#     CSV IDs to auto-generated SERIAL IDs during load,
#     then dropped in the teardown block
#   - Indexes on source_id and staging join columns
#     dramatically improve Orderline load performance
# ==============================================================

cat > /home/${USERNAME}/etl.sql <<'EOF'
--=================================================
-- ETL SQL Script for POS Database
--=================================================

-- =========================================================
-- [SEC-10] SCHEMA CREATION
-- =========================================================

USE POS;

/* City table created first so Customer can reference zip PK */
CREATE TABLE City(
  zip         DECIMAL(5,0) ZEROFILL PRIMARY KEY,
  city        VARCHAR(32),
  state  VARCHAR(4)
);
CREATE TABLE Customer(
  id          SERIAL PRIMARY KEY,
  firstName   VARCHAR(32),
  lastName    VARCHAR(30),
  email       VARCHAR(128),
  address1    VARCHAR(100),
  address2    VARCHAR(50),
  phone       VARCHAR(32),
  birthDate   DATE,
  zip         DECIMAL(5,0) ZEROFILL, 
  constraint fk_customer_city FOREIGN KEY (zip) REFERENCES City(zip)

);

/* Must use backticks — ORDER is a reserved keyword */
CREATE TABLE `Order` (
  id SERIAL   PRIMARY KEY,
  datePlaced  DATETIME,
  dateShipped DATETIME,
  customer_id BIGINT UNSIGNED,
  constraint fk_order_customer FOREIGN KEY (customer_id) REFERENCES Customer(id)
);

CREATE TABLE Product(
  id                SERIAL PRIMARY KEY,
  name              VARCHAR(128),
  currentPrice      DECIMAL(6,2),
  availableQuantity INT
);

CREATE TABLE Orderline(
  order_id    BIGINT UNSIGNED,
  product_id  BIGINT UNSIGNED,
  quantity    INT,
  PRIMARY KEY (order_id, product_id),
  constraint fk_orderline_order   FOREIGN KEY (order_id)   REFERENCES `Order`(id),
  constraint fk_orderline_product FOREIGN KEY (product_id) REFERENCES Product(id)
);

CREATE TABLE PriceHistory(
  id          SERIAL PRIMARY KEY,
  oldPrice    DECIMAL(6,2),
  newPrice    DECIMAL(6,2),
  ts          TIMESTAMP,
  product_id  BIGINT UNSIGNED,
  constraint fk_pricehistory_product FOREIGN KEY (product_id) REFERENCES Product(id)
);

-- =========================================================
-- [SEC-11] STAGING TABLE CREATION & DATA LOAD
-- =========================================================

DROP TABLE IF EXISTS stg_customers;
DROP TABLE IF EXISTS stg_products;
DROP TABLE IF EXISTS stg_orders;
DROP TABLE IF EXISTS stg_orderlines;


CREATE TABLE stg_customer (
  row_id INT AUTO_INCREMENT PRIMARY KEY,
  loaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  status VARCHAR(20) DEFAULT 'pending',

  customer_id   VARCHAR(50),
  firstName     VARCHAR(32),
  lastName      VARCHAR(30),
  city          VARCHAR(32),
  state         VARCHAR(4),
  zip           VARCHAR(10),
  address1      VARCHAR(100),
  address2      VARCHAR(50),
  email         VARCHAR(128),
  birthDate     VARCHAR(15)
  

);

LOAD DATA LOCAL INFILE '/home/adaniels/customers.csv'
INTO TABLE stg_customer
FIELDS TERMINATED BY ','
OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(customer_id, firstName, lastName, city, state, zip, address1, address2, email, birthDate);

CREATE TABLE stg_product (
  row_id INT AUTO_INCREMENT PRIMARY KEY,
  loaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  status VARCHAR(20) DEFAULT 'pending',

  product_id        VARCHAR(50),
  name VARCHAR(128),
  currentPrice      VARCHAR(20),
  availableQuantity VARCHAR(20)

);

LOAD DATA LOCAL INFILE '/home/adaniels/products.csv'
INTO TABLE stg_product
FIELDS TERMINATED BY ','
OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(product_id, name, currentPrice, availableQuantity);

CREATE TABLE stg_order (
  row_id INT AUTO_INCREMENT PRIMARY KEY,
  loaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  status VARCHAR(20) DEFAULT 'pending',

  order_id    VARCHAR(50),
  customer_id VARCHAR(50),
  datePlaced  VARCHAR(20),
  dateShipped VARCHAR(20)
  

);

LOAD DATA LOCAL INFILE '/home/adaniels/orders.csv'
INTO TABLE stg_order
FIELDS TERMINATED BY ','
OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(order_id, customer_id, datePlaced, dateShipped);



CREATE TABLE stg_orderline(
  row_id INT AUTO_INCREMENT PRIMARY KEY,
  loaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  status VARCHAR(20) DEFAULT 'pending',
  
  order_id    VARCHAR(50),
  product_id  VARCHAR(50)
);

LOAD DATA LOCAL INFILE '/home/adaniels/orderlines.csv'
INTO TABLE stg_orderline
FIELDS TERMINATED BY ','
OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(order_id, product_id);



CREATE TABLE stg_city(
  row_id INT AUTO_INCREMENT PRIMARY KEY,
  loaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  status VARCHAR(20) DEFAULT 'pending',

  zip         VARCHAR(10),
  city        VARCHAR(32),
  state       VARCHAR(4)
);

CREATE TABLE stg_pricehistory(
  row_id INT AUTO_INCREMENT PRIMARY KEY,
  loaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  status VARCHAR(20) DEFAULT 'pending',

  pricehistory_id VARCHAR(50),
  oldPrice        VARCHAR(20),
  newPrice        VARCHAR(20),
  ts              VARCHAR(20),
  product_id      VARCHAR(50)
);

-- =========================================================
-- [SEC-12] TRANSFORM & VALIDATE STAGING DATA
-- =========================================================

-- CUSTOMERS: Reject rows missing required fields
UPDATE stg_customer SET status = 'rejected'
WHERE customer_id IS NULL OR customer_id = ''
   OR firstName IS NULL OR firstName = ''
   OR lastName IS NULL OR lastName = ''
   OR email IS NULL OR email = '';

-- CUSTOMERS: Trim whitespace on all text fields
UPDATE stg_customer SET
    firstName  = TRIM(firstName),
    lastName   = TRIM(lastName),
    email      = TRIM(email),
    address1   = TRIM(address1),
    address2   = TRIM(address2),
    city       = TRIM(city),
    state      = TRIM(state),
    zip        = TRIM(zip)
WHERE status = 'pending';

-- PRODUCTS: Strip '$' and ',' from price field
UPDATE stg_product SET currentPrice = REPLACE(currentPrice, '$', '')
WHERE status = 'pending';  
UPDATE stg_product SET currentPrice = REPLACE(currentPrice, ',', '')
WHERE status = 'pending';  

-- PRODUCTS: Reject rows with missing or invalid data
UPDATE stg_product SET status = 'rejected'
WHERE product_id IS NULL OR product_id = ''
   OR name IS NULL OR name = ''
   OR currentPrice IS NULL OR currentPrice = ''
   OR (CAST(currentPrice AS DECIMAL(6,2)) <= 0);

UPDATE stg_product SET name = TRIM(name)
WHERE status = 'pending';

-- ORDERS: Reject rows missing required fields
UPDATE stg_order SET status = 'rejected'
WHERE order_id IS NULL OR order_id = ''
   OR customer_id IS NULL OR customer_id = '';

-- ORDERLINES: Reject rows missing required fields
UPDATE stg_orderline SET status = 'rejected'
WHERE order_id IS NULL OR order_id = ''
   OR product_id IS NULL OR product_id = '';

-- ORDERS: Convert 'Cancelled' dateShipped values to NULL
UPDATE stg_order SET dateShipped = NULL
WHERE status = 'pending'
  AND LOWER(dateShipped) = 'cancelled';

-- =========================================================
-- [SEC-13] LOAD INTO PRODUCTION TABLES
-- =========================================================

-- Add temporary source_id columns to map CSV IDs → SERIAL IDs
ALTER TABLE Customer ADD COLUMN source_id VARCHAR(50);
ALTER TABLE Product ADD COLUMN source_id VARCHAR(50);
ALTER TABLE `Order` ADD COLUMN source_id VARCHAR(50);

-- LOAD: CITY
INSERT IGNORE INTO City (zip, city, state)
SELECT DISTINCT
    CAST(zip AS DECIMAL(5,0)),
    TRIM(city),
    TRIM(state)
FROM stg_customer
WHERE status = 'pending'
  AND zip IS NOT NULL AND zip != '';

-- LOAD: CUSTOMER
INSERT INTO Customer (firstName, lastName, email, address1, address2, birthDate, zip, source_id)
SELECT
    firstName,
    lastName,
    email,
    address1,
    address2,
    STR_TO_DATE(birthDate, '%c/%e/%Y'),
    CAST(zip AS DECIMAL(5,0)),
    customer_id
FROM stg_customer
WHERE status = 'pending';

-- LOAD: PRODUCT
INSERT INTO Product (name, currentPrice, availableQuantity, source_id)
SELECT
    TRIM(name),
    CAST(currentPrice AS DECIMAL(6,2)),
    CAST(availableQuantity AS UNSIGNED),
    product_id
FROM stg_product
WHERE status = 'pending';

-- LOAD: ORDER
INSERT INTO `Order` (datePlaced, dateShipped, customer_id, source_id)
SELECT
    o.datePlaced,
    o.dateShipped,
    c.id,
    o.order_id
FROM stg_order o
JOIN Customer c ON c.source_id = o.customer_id
WHERE o.status = 'pending';

-- Add indexes to source_id columns to speed up Orderline JOIN
-- (Query performance was extremely slow without these)
ALTER TABLE `Order` ADD INDEX idx_source_id (source_id);
ALTER TABLE Product ADD INDEX idx_source_id (source_id);
ALTER TABLE stg_orderline ADD INDEX idx_order_id (order_id);
ALTER TABLE stg_orderline ADD INDEX idx_product_id (product_id);

-- LOAD: ORDERLINE
-- Performance drastically improved by adding indexes above
INSERT INTO Orderline (order_id, product_id, quantity)
SELECT
    o.id,
    p.id,
    COUNT(*) AS quantity
FROM stg_orderline sl
JOIN `Order` o ON o.source_id = sl.order_id
JOIN Product p ON p.source_id = sl.product_id
WHERE sl.status = 'pending'
GROUP BY o.id, p.id;

/*
-- PriceHistory intentionally NOT seeded here.
-- It is populated exclusively by the trg_after_product_update
-- trigger defined in views.sql (see [SEC-17]).
*/

-- =========================================================
-- [SEC-14] TEARDOWN — DROP source_id & STAGING TABLES
-- =========================================================

ALTER TABLE Customer DROP COLUMN source_id;
ALTER TABLE Product DROP COLUMN source_id;
ALTER TABLE `Order` DROP COLUMN source_id;

DROP TABLE IF EXISTS stg_customer;
DROP TABLE IF EXISTS stg_product;
DROP TABLE IF EXISTS stg_order;
DROP TABLE IF EXISTS stg_orderline;
DROP TABLE IF EXISTS stg_city;
DROP TABLE IF EXISTS stg_pricehistory;


EOF


# ==============================================================
# [SEC-15] ETL SCRIPT — EXECUTE
# ==============================================================
# Run etl.sql as the unprivileged MariaDB user with
# --local-infile=1 to permit LOAD DATA LOCAL INFILE.
# Uses su - to ensure the user's environment is loaded.
# ==============================================================

chown "${USERNAME}:${USERNAME}" /home/${USERNAME}/etl.sql
chmod 640 /home/${USERNAME}/etl.sql

touch /root/9-etl-sql-written

sudo su - ${USERNAME} -c "mariadb --local-infile=1 -u ${USERNAME} -p'${PASSWORD}' < /home/${USERNAME}/etl.sql"

touch /root/10-etl-sql-executed


# ==============================================================
# [SEC-16] VIEWS & MATERIALIZED VIEWS
# [SEC-17] TRIGGERS (ORDERLINE SYNC & PRICE HISTORY)
# [SEC-18] VIEWS/TRIGGERS SCRIPT — EXECUTE
# ==============================================================
# views.sql creates:
#   - v_ProductBuyers:  live VIEW joining Product → Orderline
#                       → Order → Customer with GROUP_CONCAT
#   - mv_ProductBuyers: physical snapshot (materialized view)
#                       kept in sync by triggers
#   - trg_after_orderline_insert / _delete: refresh the
#     mv_ProductBuyers row for the affected product
#   - trg_after_product_update: log price changes to
#     PriceHistory when currentPrice is modified
#
# NOTE: DELIMITER $$ is required so MariaDB does not
# misinterpret semicolons inside BEGIN...END trigger bodies.
# ==============================================================

cat > /home/${USERNAME}/views.sql <<'EOF'

USE POS;

-- =========================================================
-- [SEC-16] VIEW: v_ProductBuyers
-- =========================================================
-- Lists all customers who purchased each product.
-- LEFT JOIN ensures products with no sales still appear.
-- =========================================================
CREATE OR REPLACE VIEW v_ProductBuyers AS
SELECT
    p.id   AS productID,
    p.name AS productName,
    GROUP_CONCAT(
        DISTINCT CONCAT(c.id, ' ', c.firstName, ' ', c.lastName)
        ORDER BY c.id
        SEPARATOR ', '
    ) AS customers
FROM Product p
LEFT JOIN Orderline ol ON p.id = ol.product_id
LEFT JOIN `Order`   o  ON ol.order_id = o.id
LEFT JOIN Customer  c  ON o.customer_id = c.id
GROUP BY p.id, p.name
ORDER BY p.id;


-- =========================================================
-- [SEC-16] MATERIALIZED VIEW: mv_ProductBuyers
-- =========================================================
-- Simulated via a physical snapshot table.
-- =========================================================
DROP TABLE IF EXISTS mv_ProductBuyers;

CREATE TABLE mv_ProductBuyers AS
SELECT * FROM v_ProductBuyers;

CREATE INDEX idx_productID ON mv_ProductBuyers(productID);


-- =========================================================
-- [SEC-17] TRIGGERS
-- =========================================================

DELIMITER $$ 

-- Fires when a new orderline is inserted
CREATE TRIGGER trg_after_orderline_insert
AFTER INSERT ON Orderline
FOR EACH ROW
BEGIN
    UPDATE mv_ProductBuyers
    SET customers = (
        SELECT GROUP_CONCAT(
                   DISTINCT CONCAT(c.id, ' ', c.firstName, ' ', c.lastName)
                   ORDER BY c.id
                   SEPARATOR ', '
               )
        FROM Orderline ol
        JOIN POS.Order  o ON ol.order_id  = o.id
        JOIN Customer c ON o.customer_id = c.id
        WHERE ol.product_id = NEW.product_id
    )
    WHERE productID = NEW.product_id;
END$$


-- Fires when an orderline is deleted
CREATE TRIGGER trg_after_orderline_delete
AFTER DELETE ON Orderline
FOR EACH ROW
BEGIN
    UPDATE mv_ProductBuyers
    SET customers = (
        SELECT GROUP_CONCAT(
                   DISTINCT CONCAT(c.id, ' ', c.firstName, ' ', c.lastName)
                   ORDER BY c.id
                   SEPARATOR ', '
               )
        FROM Orderline ol
        JOIN `Order`  o ON ol.order_id  = o.id
        JOIN Customer c ON o.customer_id = c.id
        WHERE ol.product_id = OLD.product_id
    )
    WHERE productID = OLD.product_id;
END$$


-- Log price changes to PriceHistory
CREATE TRIGGER trg_after_product_update
AFTER UPDATE ON Product
FOR EACH ROW
BEGIN
    IF OLD.currentPrice <> NEW.currentPrice THEN
        INSERT INTO PriceHistory (oldPrice, newPrice, ts, product_id)
        VALUES (OLD.currentPrice, NEW.currentPrice, NOW(), NEW.id);
    END IF;
END$$

EOF


# ==============================================================
# [SEC-18] VIEWS/TRIGGERS SCRIPT — EXECUTE
# ==============================================================

touch /root/11-views-sql-written

chown "${USERNAME}:${USERNAME}" /home/${USERNAME}/views.sql
chmod 640 /home/${USERNAME}/views.sql

sudo su - ${USERNAME} -c "mariadb --local-infile=1 -u ${USERNAME} -p'${PASSWORD}' < /home/${USERNAME}/views.sql"

touch /root/12-views-sql-executed


# ==============================================================
# [SEC-19] JSON EXPORT — DIRECTORY SETUP
# ==============================================================
# Create /var/lib/mysql-files/ and set ownership to the mysql
# OS user so MariaDB's SELECT ... INTO OUTFILE can write there.
# (Fixes Errcode 13 — permission denied)
# ==============================================================

sudo mkdir -p /var/lib/mysql-files/
sudo chown mysql:mysql /var/lib/mysql-files/
sudo chmod 750 /var/lib/mysql-files/


# ==============================================================
# [SEC-20] JSON EXPORT — prod.json
# [SEC-21] JSON EXPORT — cust.json
# [SEC-22] JSON EXPORT — custom1.json (REGIONAL SALES)
# [SEC-23] JSON EXPORT — custom2.json (CUSTOMER LIFETIME VALUE)
# [SEC-24] JSON EXPORT SCRIPT — EXECUTE
# ==============================================================
# xjson.sql builds four nested JSON documents directly from
# the relational POS schema using MariaDB's JSON functions
# and SELECT ... INTO OUTFILE.
#
# Key fixes applied during development:
#   - Errcode 13: resolved by chown to mysql OS user [SEC-19]
#   - JSON validation failures: pipe-char formatting from
#     MariaDB terminal; fixed by reading file with head -n 1
#   - Leading-zero ZIPs: DECIMAL(5,0) ZEROFILL produces
#     JSON-invalid numbers; fixed with CAST(ct.zip AS CHAR)
# ==============================================================

cat > /home/${USERNAME}/xjson.sql <<'EOF'

-- =========================================================
-- [SEC-20] prod.json — Product → Customers
-- =========================================================

USE POS;

SELECT JSON_OBJECT(
    'ProductID',    p.id,
    'currentPrice', p.currentPrice,
    'productName',  p.name,
    'customers',    COALESCE(
        (SELECT JSON_ARRAYAGG(
            JSON_OBJECT(
                'CustomerID',   c.id,
                'CustomerName', CONCAT(c.firstName, ' ', c.lastName)
            )
        )
        FROM Orderline ol
        JOIN `Order` o  ON ol.order_id  = o.id
        JOIN Customer c ON o.customer_id = c.id
        WHERE ol.product_id = p.id
        ),
        JSON_ARRAY()
    )
)
FROM Product p
INTO OUTFILE '/var/lib/mysql-files/prod.json';

-- =========================================================
-- [SEC-21] cust.json — Customer → Orders → Items
-- =========================================================

-- CTE 1: Build the Items array and order total per order
WITH order_items AS (
    SELECT
        ol.order_id,
        SUM(ol.quantity * p.currentPrice) AS order_total,
        JSON_ARRAYAGG(
            JSON_OBJECT(
                'ProductID',   p.id,
                'Quantity',    ol.quantity,
                'ProductName', p.name
            )
        ) AS items
    FROM Orderline ol
    JOIN Product p ON ol.product_id = p.id
    GROUP BY ol.order_id
),

-- CTE 2: Wrap items into the Orders array per customer
customer_orders AS (
    SELECT
        o.customer_id,
        JSON_ARRAYAGG(
            JSON_OBJECT(
                'OrderTotal',   oi.order_total,
                'OrderDate',    o.datePlaced,
                'ShippingDate', o.dateShipped,
                'Items',        oi.items
            )
        ) AS orders
    FROM `Order` o
    JOIN order_items oi ON o.id = oi.order_id
    GROUP BY o.customer_id
)

-- Final: Build the root Customer object
SELECT JSON_OBJECT(
    'customer_name',      CONCAT(c.firstName, ' ', c.lastName),
    'printed_address_1',  CASE
                              WHEN c.address2 IS NOT NULL AND c.address2 != ''
                              THEN CONCAT(c.address1, ' #', c.address2)
                              ELSE c.address1
                          END,
    'printed_address_2',  CONCAT(ct.city, ', ', ct.state, '   ', ct.zip),
    'orders',             COALESCE(co.orders, JSON_ARRAY())
)
FROM Customer c
LEFT JOIN City ct             ON c.zip = ct.zip
LEFT JOIN customer_orders co  ON c.id  = co.customer_id
INTO OUTFILE '/var/lib/mysql-files/cust.json';


-- =========================================================
-- [SEC-22] custom1.json — Regional Sales Performance
-- =========================================================

WITH region_product_stats AS (
    SELECT
        c.zip,
        p.id    AS product_id,
        p.name  AS product_name,
        SUM(ol.quantity)                AS total_qty,
        SUM(ol.quantity * p.currentPrice) AS revenue
    FROM Customer c
    JOIN `Order` o    ON o.customer_id  = c.id
    JOIN Orderline ol ON ol.order_id    = o.id
    JOIN Product p    ON ol.product_id  = p.id
    GROUP BY c.zip, p.id, p.name
),

region_products AS (
    SELECT
        zip,
        SUM(total_qty) AS total_units_sold,
        SUM(revenue)   AS total_revenue,
        JSON_ARRAYAGG(
            JSON_OBJECT(
                'ProductID',    product_id,
                'ProductName',  product_name,
                'QuantitySold', total_qty,
                'Revenue',      revenue
            )
        ) AS products
    FROM region_product_stats
    GROUP BY zip
),

region_customers AS (
    SELECT
        c.zip,
        JSON_ARRAYAGG(
            JSON_OBJECT(
                'CustomerID',   c.id,
                'CustomerName', CONCAT(c.firstName, ' ', c.lastName)
            )
        ) AS customers
    FROM Customer c
    GROUP BY c.zip
)

SELECT JSON_OBJECT(
    'city',             ct.city,
    'state',            ct.state,
    'zip',              CAST(ct.zip AS CHAR),
    'total_revenue',    COALESCE(rp.total_revenue, 0),
    'total_units_sold', COALESCE(rp.total_units_sold, 0),
    'customer_count',   (SELECT COUNT(*) FROM Customer c2 WHERE c2.zip = ct.zip),
    'products_sold',    COALESCE(rp.products, JSON_ARRAY()),
    'customers',        COALESCE(rc.customers, JSON_ARRAY())
)
FROM City ct
LEFT JOIN region_products rp  ON ct.zip = rp.zip
LEFT JOIN region_customers rc ON ct.zip = rc.zip
INTO OUTFILE '/var/lib/mysql-files/custom1.json';


-- =========================================================
-- [SEC-23] custom2.json — Customer Lifetime Value Profile
-- =========================================================

WITH customer_product_stats AS (
    SELECT
        o.customer_id,
        p.id    AS product_id,
        p.name  AS product_name,
        SUM(ol.quantity)                  AS total_qty,
        SUM(ol.quantity * p.currentPrice) AS total_spent
    FROM `Order` o
    JOIN Orderline ol ON ol.order_id   = o.id
    JOIN Product p    ON ol.product_id = p.id
    GROUP BY o.customer_id, p.id, p.name
),

customer_products AS (
    SELECT
        customer_id,
        JSON_ARRAYAGG(
            JSON_OBJECT(
                'ProductID',     product_id,
                'ProductName',   product_name,
                'TotalQuantity', total_qty,
                'TotalSpent',    total_spent
            )
        ) AS products_purchased
    FROM customer_product_stats
    GROUP BY customer_id
),

customer_spend AS (
    SELECT
        o.customer_id,
        COUNT(DISTINCT o.id)              AS order_count,
        SUM(ol.quantity * p.currentPrice) AS lifetime_spend
    FROM `Order` o
    JOIN Orderline ol ON ol.order_id   = o.id
    JOIN Product p    ON ol.product_id = p.id
    GROUP BY o.customer_id
)

SELECT JSON_OBJECT(
    'CustomerID',          c.id,
    'customer_name',       CONCAT(c.firstName, ' ', c.lastName),
    'email',               c.email,
    'lifetime_spend',      COALESCE(cs.lifetime_spend, 0),
    'order_count',         COALESCE(cs.order_count, 0),
    'avg_order_value',     COALESCE(ROUND(cs.lifetime_spend / cs.order_count, 2), 0),
    'products_purchased',  COALESCE(cp.products_purchased, JSON_ARRAY())
)
FROM Customer c
LEFT JOIN customer_spend cs    ON c.id = cs.customer_id
LEFT JOIN customer_products cp ON c.id = cp.customer_id
INTO OUTFILE '/var/lib/mysql-files/custom2.json';

EOF


# ==============================================================
# [SEC-24] JSON EXPORT SCRIPT — EXECUTE
# ==============================================================

sudo su - ${USERNAME} -c "mariadb --local-infile=1 -u ${USERNAME} -p'${PASSWORD}' < /home/${USERNAME}/xjson.sql"


# ==============================================================
# [SEC-25] INSTALL MONGODB 8.0
# ==============================================================
# Import the MongoDB GPG signing key, add the official
# MongoDB 8.0 repository for Ubuntu Noble, install the
# mongodb-org metapackage, and start/enable the mongod service.
# ==============================================================

# Import MongoDB GPG key
curl -fsSL https://www.mongodb.org/static/pgp/server-8.0.asc | \
  sudo gpg --dearmor -o /usr/share/keyrings/mongodb-server-8.0.gpg

# Add the MongoDB 8.0 repo for Noble
echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] https://repo.mongodb.org/apt/ubuntu noble/mongodb-org/8.0 multiverse" | \
  sudo tee /etc/apt/sources.list.d/mongodb-org-8.0.list

# Install
sudo apt update
sudo apt install -y mongodb-org

# Start & enable
sudo systemctl start mongod
sudo systemctl enable mongod


# ==============================================================
# [SEC-26] MONGODB SYNC PIPELINE (sync.sh)
# ==============================================================
# sync.sh is a standalone script that:
#   1. Removes stale JSON files from /var/lib/mysql-files/
#   2. Re-runs xjson.sql to regenerate fresh exports
#   3. Uses mongoimport with --drop to replace each
#      MongoDB collection with the latest data
#
# This script is called once at provision time and then
# scheduled via cron in [SEC-27].
# ==============================================================

cat > /home/${USERNAME}/sync.sh <<'EOF'
#!/bin/bash

# Remove existing JSON files to prevent stale data
rm -f /var/lib/mysql-files/*.json

# Re-run the SQL file to regenerate JSON exports
mariadb -u root < /home/adaniels/xjson.sql

# Import JSON files into MongoDB
mongoimport --db FurnitureDB --collection Products --file /var/lib/mysql-files/prod.json --drop
mongoimport --db FurnitureDB --collection Customers --file /var/lib/mysql-files/cust.json --drop
mongoimport --db FurnitureDB --collection Region --file /var/lib/mysql-files/custom1.json --drop
mongoimport --db FurnitureDB --collection CusHistory --file /var/lib/mysql-files/custom2.json --drop

echo "Pipeline Sync Completed Successfully"
EOF

chown "${USERNAME}:${USERNAME}" /home/${USERNAME}/sync.sh
chmod 750 /home/${USERNAME}/sync.sh

# Run initial sync
bash /home/${USERNAME}/sync.sh


# ==============================================================
# [SEC-27] CRON JOB — SCHEDULED SYNC
# ==============================================================
# Schedule sync.sh to run every minute (adjustable) to keep
# MongoDB collections in sync with MariaDB. Output is
# appended to /var/log/sync.log for monitoring.
# ==============================================================

(crontab -l 2>/dev/null; echo "* * * * * /home/${USERNAME}/sync.sh >> /var/log/sync.log 2>&1") | crontab -

echo "=== AUTOSCRIPT1.0 COMPLETE — All systems provisioned ==="
