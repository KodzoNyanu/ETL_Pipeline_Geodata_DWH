table 50103 "ETL Ecommerce Line"
{
    Caption = 'ETL Ecommerce Line';
    DataClassification = CustomerContent;

    fields
    {
        field(1; "Invoice No"; Code[20])
        {
            Caption = 'Invoice No';
            DataClassification = CustomerContent;
        }
        field(2; "Line No"; Integer)
        {
            Caption = 'Line No';
            DataClassification = CustomerContent;
        }
        field(3; "Stock Code"; Code[50])
        {
            Caption = 'Stock Code';
            DataClassification = CustomerContent;
        }
        field(4; "Description"; Text[100])
        {
            Caption = 'Description';
            DataClassification = CustomerContent;
        }
        field(5; "Quantity"; Decimal)
        {
            Caption = 'Quantity';
            DataClassification = CustomerContent;
        }
        field(6; "Unit Price"; Decimal)
        {
            Caption = 'Unit Price';
            DataClassification = CustomerContent;
        }
        field(7; "Total Amount"; Decimal)
        {
            Caption = 'Total Amount';
            DataClassification = CustomerContent;
        }
        field(8; "Customer Id"; Code[50])
        {
            Caption = 'Customer Id';
            DataClassification = CustomerContent;
        }
        field(9; "Country"; Code[10])
        {
            Caption = 'Country';
            DataClassification = CustomerContent;
        }
        field(10; "Invoice Date"; Date)
        {
            Caption = 'Invoice Date';
            DataClassification = CustomerContent;
        }
        field(11; "ETL Loaded At"; DateTime)
        {
            Caption = 'ETL Loaded At';
            DataClassification = SystemMetadata;
        }
    }

    keys
    {
        key(PK; "Invoice No", "Line No")
        {
            Clustered = true;
        }
    }
}
