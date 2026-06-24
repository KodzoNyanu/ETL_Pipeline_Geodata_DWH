table 50101 "ETL Distance"
{
    Caption = 'ETL Distance';
    DataClassification = CustomerContent;

    fields
    {
        field(1; "Origin"; Text[250])
        {
            Caption = 'Origin';
            DataClassification = CustomerContent;
        }
        field(2; "Destination"; Text[250])
        {
            Caption = 'Destination';
            DataClassification = CustomerContent;
        }
        field(3; "Distance Km"; Decimal)
        {
            Caption = 'Distance (km)';
            DataClassification = CustomerContent;
        }
        field(4; "Duration Min"; Decimal)
        {
            Caption = 'Duration (min)';
            DataClassification = CustomerContent;
        }
        field(5; "ETL Loaded At"; DateTime)
        {
            Caption = 'ETL Loaded At';
            DataClassification = SystemMetadata;
        }
    }

    keys
    {
        key(PK; "Origin", "Destination")
        {
            Clustered = true;
        }
    }
}
