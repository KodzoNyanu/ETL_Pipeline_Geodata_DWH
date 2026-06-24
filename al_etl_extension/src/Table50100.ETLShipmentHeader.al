table 50100 "ETL Shipment Header"
{
    Caption = 'ETL Shipment Header';
    DataClassification = CustomerContent;

    fields
    {
        field(1; "Header Id"; Code[50])
        {
            Caption = 'Header Id';
            DataClassification = CustomerContent;
        }
        field(2; "Customer No"; Code[20])
        {
            Caption = 'Customer No';
            DataClassification = CustomerContent;
        }
        field(3; "Order No"; Code[20])
        {
            Caption = 'Order No';
            DataClassification = CustomerContent;
        }
        field(4; "Shipment Date"; Date)
        {
            Caption = 'Shipment Date';
            DataClassification = CustomerContent;
        }
        field(5; "Ship To City"; Text[100])
        {
            Caption = 'Ship To City';
            DataClassification = CustomerContent;
        }
        field(6; "Ship To Country"; Code[10])
        {
            Caption = 'Ship To Country';
            DataClassification = CustomerContent;
        }
        field(7; "ETL Loaded At"; DateTime)
        {
            Caption = 'ETL Loaded At';
            DataClassification = SystemMetadata;
        }
    }

    keys
    {
        key(PK; "Header Id")
        {
            Clustered = true;
        }
    }
}
