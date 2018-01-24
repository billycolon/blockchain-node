# coding: utf-8

"""
    Aeternity Epoch

    This is the [Aeternity](https://www.aeternity.com/) Epoch API.

    OpenAPI spec version: 1.0.0
    Contact: apiteam@aeternity.com
    Generated by: https://github.com/swagger-api/swagger-codegen.git
"""


from pprint import pformat
from six import iteritems
import re


class GenericTxObject(object):
    """
    NOTE: This class is auto generated by the swagger code generator program.
    Do not edit the class manually.
    """


    """
    Attributes:
      swagger_types (dict): The key is attribute name
                            and the value is attribute type.
      attribute_map (dict): The key is attribute name
                            and the value is json key in definition.
    """
    swagger_types = {
        'type': 'str',
        'vsn': 'int'
    }

    attribute_map = {
        'type': 'type',
        'vsn': 'vsn'
    }

    def __init__(self, type=None, vsn=None):
        """
        GenericTxObject - a model defined in Swagger
        """

        self._type = None
        self._vsn = None

        self.type = type
        if vsn is not None:
          self.vsn = vsn

    @property
    def type(self):
        """
        Gets the type of this GenericTxObject.

        :return: The type of this GenericTxObject.
        :rtype: str
        """
        return self._type

    @type.setter
    def type(self, type):
        """
        Sets the type of this GenericTxObject.

        :param type: The type of this GenericTxObject.
        :type: str
        """
        if type is None:
            raise ValueError("Invalid value for `type`, must not be `None`")

        self._type = type

    @property
    def vsn(self):
        """
        Gets the vsn of this GenericTxObject.

        :return: The vsn of this GenericTxObject.
        :rtype: int
        """
        return self._vsn

    @vsn.setter
    def vsn(self, vsn):
        """
        Sets the vsn of this GenericTxObject.

        :param vsn: The vsn of this GenericTxObject.
        :type: int
        """

        self._vsn = vsn

    def to_dict(self):
        """
        Returns the model properties as a dict
        """
        result = {}

        for attr, _ in iteritems(self.swagger_types):
            value = getattr(self, attr)
            if isinstance(value, list):
                result[attr] = list(map(
                    lambda x: x.to_dict() if hasattr(x, "to_dict") else x,
                    value
                ))
            elif hasattr(value, "to_dict"):
                result[attr] = value.to_dict()
            elif isinstance(value, dict):
                result[attr] = dict(map(
                    lambda item: (item[0], item[1].to_dict())
                    if hasattr(item[1], "to_dict") else item,
                    value.items()
                ))
            else:
                result[attr] = value

        return result

    def to_str(self):
        """
        Returns the string representation of the model
        """
        return pformat(self.to_dict())

    def __repr__(self):
        """
        For `print` and `pprint`
        """
        return self.to_str()

    def __eq__(self, other):
        """
        Returns true if both objects are equal
        """
        if not isinstance(other, GenericTxObject):
            return False

        return self.__dict__ == other.__dict__

    def __ne__(self, other):
        """
        Returns true if both objects are not equal
        """
        return not self == other
