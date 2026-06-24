table 50102 "ETL Shipment Line"
{
    Caption = 'ETL Shipment Line';
    DataClassification = CustomerContent;

    fields
    {
        field(1; "Document No"; Code[20])
        {
            Caption = 'Document No';
            DataClassification = CustomerContent;
        }
        field(2; "Line No"; Integer)
        {
            Caption = 'Line No';
            DataClassification = CustomerContent;
        }
        field(3; "Article Id"; Code[50])
        {
            Caption = 'Article Id';
            DataClassification = CustomerContent;
        }
        field(4; "Quantity"; Decimal)
        {
            Caption = 'Quantity';
            DataClassification = CustomerContent;
        }
        field(5; "Location Code"; Code[10])
        {
            Caption = 'Location Code';
            DataClassification = CustomerContent;
        }
        field(6; "ETL Loaded At"; DateTime)
        {
            Caption = 'ETL Loaded At';
            DataClassification = SystemMetadata;
        }
    }

    keys
    {
        key(PK; "Document No", "Line No")
        {
            Clustered = true;
        }
    }
}
