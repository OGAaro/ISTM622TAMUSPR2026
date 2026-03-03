# POS ETL Pipeline — Automated AWS EC2 & MariaDB Setup

An automated Extract, Transform, Load (ETL) pipeline for a Point of Sale (POS) database system. This project provisions an AWS EC2 instance, installs and configures MariaDB, and processes raw CSV source files into a normalized relational database — entirely without manual intervention.

---

## Overview

This pipeline is triggered via an **AWS EC2 User Data script** at instance launch. It handles:

- Automated MariaDB installation and configuration
- Unprivileged database user creation with targeted security permissions
- Schema creation across six normalized tables
- Data cleaning and transformation of four CSV source files
- Loading of cleaned data into the database using `LOAD DATA LOCAL INFILE`
- Index creation for query performance optimization

---

## Database Schema

The database models a retail POS system with the following six tables:

| Table          | Description                                      |
|----------------|--------------------------------------------------|
| `City`         | City and region reference data                   |
| `Customer`     | Customer records linked to City                  |
| `Product`      | Product catalog with pricing                     |
| `` `Order` ``  | Customer order headers                           |
| `Orderline`    | Individual line items per order                  |
| `PriceHistory` | Historical product pricing records               |

> **Note:** `Order` is a MariaDB reserved word and must be wrapped in backticks in all queries.

---

## Tech Stack

- **Cloud:** AWS EC2 (Ubuntu)
- **Database:** MariaDB
- **Scripting:** Bash
- **Data Format:** CSV
- **Automation:** EC2 User Data scripts

---

## How It Works

1. **Launch** an EC2 Ubuntu instance with the User Data script attached
2. The script **automatically**:
   - Installs MariaDB and sets up the service
   - Creates an unprivileged DB user with a targeted `sudoers` rule
   - Executes the schema SQL to build all six tables
   - Cleans and transforms CSV source data using SQL functions:
     - `STR_TO_DATE()` for date format normalization
     - `REPLACE()` for price field sanitization
     - `COUNT(*) GROUP BY` to resolve duplicate `Orderline` records
   - Loads data via `LOAD DATA LOCAL INFILE`
   - Creates indexes on foreign key and frequently queried columns
3. **Verify** the load using the included verification queries

---

## Key Implementation Details

- **Staging tables** are used to validate and transform data before inserting into production tables
- **Foreign key consistency** is maintained by matching `SERIAL` primary keys (`BIGINT UNSIGNED`) with identical types on all foreign key columns
- **Indexes** are added after initial data load to significantly reduce query execution time
- **Logging** is written to `/var/log/user-data.log` for debugging automation runs
- MariaDB binary PATH is explicitly configured to avoid execution issues in non-interactive shell environments

---

## Repository Structure

```
pos-etl-pipeline/
├── userdata.sh        # Main EC2 User Data automation script
├── schema.sql         # Database schema definition
├── load_data.sql      # Data cleaning, transformation, and load logic
├── verify.sql         # Verification queries to confirm successful load
├── .gitignore
└── README.md
```

---

## Getting Started

### Prerequisites
- AWS account with EC2 access
- An Ubuntu EC2 AMI
- CSV source data files accessible to the instance (e.g., via S3 or bundled with the script)

### Deployment
1. Clone this repository
2. Place your CSV source files in the expected directory (see `userdata.sh` for paths)
3. Launch an EC2 Ubuntu instance and paste the contents of `userdata.sh` into the **User Data** field under **Advanced Details**
4. Monitor progress via:
   ```bash
   sudo tail -f /var/log/user-data.log
   ```

---

## .gitignore Recommendations

```
*.csv       # Do not commit source data files
*.log       # Do not commit log output
*.pem       # Never commit AWS key pairs
.env        # No credentials or secrets
```

---

## License

For academic use. See your institution's academic integrity policy regarding code sharing.
